# Ordered Search Autocompletion With Redis

参考资料：
http://thorstenball.com/blog/2012/06/08/search-autocompletion-with-redis/

http://patshaughnessy.net/2011/11/29/two-ways-of-using-redis-to-build-a-nosql-autocomplete-search-index

http://oldblog.antirez.com/post/autocomplete-with-redis.html


当一个用户在搜索框输入一些内容的时候，我们需要展示给用户和输入内容匹配的电影，这意味着我们第一件事要
做的就是把电影信息存放在redis中，每个电影有它唯一的主键，可以使用MD5自己生成，现在假设我们已经有了
唯一的主键，我们有十部电影：

```ruby
HSET moviesearch:data 1 "{\"name\":\"Kill Bill\",\"year\":2003}"
HSET moviesearch:data 2 "{\"name\":\"King Kong\",\"year\":2005}"
HSET moviesearch:data 3 "{\"name\":\"Killer Elite\",\"year\":2011}"
HSET moviesearch:data 4 "{\"name\":\"Kill Bill 2\",\"year\":2004}"
HSET moviesearch:data 5 "{\"name\":\"Kilts for Bill\",\"year\":2027}"
HSET moviesearch:data 6 "{\"name\":\"Kids\",\"year\":1995}"
HSET moviesearch:data 7 "{\"name\":\"Kindergarten Cop\",\"year\":1990}"
HSET moviesearch:data 8 "{\"name\":\"The Green Mile\",\"year\":1999}"
HSET moviesearch:data 9 "{\"name\":\"The Dark Knight\",\"year\":2008}"
HSET moviesearch:data 10 "{\"name\":\"The Dark Knight Rises\",\"year\":2012}"
```

通过HSET将电影信息保存到hash，以moviesearch:data作为key，通过ruby我们可以轻松的在redis
和ruby之间进行转换。

```ruby
require 'json'
# Before dumping to Redis:
{name: 'Kill Bill', year: 2003}.to_json
# => "{\"name\":\"Kill Bill\",\"year\":2003}"
# After retrieving from Redis:
JSON.parse("{\"name\":\"Kill Bill\",\"year\":2003}")
# => {"name"=>"Kill Bill", "year"=>2003}
```

顺便说一下，这里使用redis－rb作为Ruby连接Redis的工具，好，现在我们已经把电影存到Redis中了，下面看一下如何查找？

通常，我们在搜索一个电影名字的时候，我们需要输入电影的名字到搜索框，而我们要做的是当用户还没有完全输入完电影名字的时候，展示于之匹配的几个电影供其选择，也就是自动补全，比如要搜索hello的时候，可以通过输入he, hel, hell, hello自动补全，先把电影名字拆分搜索前缀。

```ruby
def prefixes_for(string)
  prefixes = []
  words    = string.downcase.split(' ')
  words.each do |word|
    (1..word.length).each do |i| 
      prefixes << word[0...i] unless i == 1
    end
  end
  prefixes
end
```

简单算法： 以空格拆分电影名字，然后对每个单词进行迭代拆分，从第二个字母往后依次进行截取作为搜索的前缀，效果如下：

```ruby
ruby prefixes_for('The Dark Knight')
＃ => ["th", "the", "da", "dar", "dark", 
    "kn", "kni", "knig", "knigh", "knight"
   ]


prefixes_for('The Dark Knight Rises')
# => ["th", "the", "da", "dar", "dark", 
      "kn", "kni", "knig", "knigh", "knight", 
      "ri", "ris", "rise", "rises"
     ]
```

我们需要为每个电影名字都生成这样的前缀，这里我们取最小的前缀长度为2，当然用户可能从电影名字的任意位置进行搜索，比如试用fi, fis, fish来搜索Fish，我们也可以通过fi, fis, fish, is, ish, sh.但是大部分用户还是喜欢从开头进行搜索的。好，下面，我们把这些前缀保存到sorted set中。

Redis试用sorted sets(有序集合)来存储唯一字符串的列表，并提供按得分进行排序，现在我们可以忽略得分，只要保证搜索结果里面不会出现相同电影名即可，我们试用moviesearch:index:$PREFIX来分别存储这些前缀。前缀对应的值为电影的主键

```ruby
ZADD moviesearch:index:dar 0 8
ZADD moviesearch:index:dar 0 9
```

这样当我们搜索dar的时候， 实际上是在Redis中搜索的是moviesearch:index:dar，返回moviesearch:data中对应电影的id，我们来构造这样的一个方法：

```ruby
def add_movie(movie_name, data_hash_key)
  prefixes = prefixes_for(movie_name)
  prefixes.each do |prefix|
    REDIS.zadd(
      "moviesearch:index:#{prefix}", 0, data_hash_key
    )
  end
end
```

```ruby
$ redis-cli ZRANGE moviesearch:index:dar 0 -1
1) "9"
2) "10"
```

```ruby
$ redis-cli HMGET moviesearch:data 9 10
1) "{\"name\":\"The Dark Knight Rises\",\"year\":2008}"
2) "{\"name\":\"The Dark Knight\",\"year\":2008}"
```

好，现在我们可以通过dar来搜索到所有以dar开头的电影了，但是有可能会有这种情况，当一个用户输入ki bi的时候，我们要展示给他him Kill Bill, Kill Bill 2, Kilts for Bill三部电影，这意味着电影名字中包含ki和bi，我们可以通过Redis' ZINTERSTORE实现，将两次的搜索结果进行合并后存到moviesearch:index:ki|bi中，然后通过ZRANGE进行搜索。

```ruby
$ redis-cli> ZINTERSTORE moviesearch:index:ki|bi 
    2 moviesearch:index:ki moviesearch:index:bi

$ redis-cli> ZRANGE 'moviesearch:index:ki|bi'
1) "1"
2) "4"
3) "5"
```

好了，这个问题也搞定了，那么问题又来了，假设用户输入ki bi的时候，实际上是想看Kindergarten Cop这部电影，而不是Kill Bill。上面我们在存储前缀的时候，得分score都设为0。为了实现这个需求，我们需要通过ZINCRBY来给电影重新打分，然后通过ZREVRANGE来获取按得分从大到小的排序结果，我们只需要
给Kindergarten Cop这部影片的得分＋1，即可得到我们想要的结果。

```ruby
def incr_score_for(movie_name, data_hash_key)
  prefixes    = prefixes_for(movie_name)
  prefixes.each do |prefix|
    REDIS.zincrby(
      index_key_for(prefix), 1, data_hash_key
    )
  end
end

```

```ruby
def find_by_prefixes(prefixes)
  intersection_key = index_key_for(prefixes)
  index_keys       = prefixes.map {|prefix| index_key_for(prefix)}

  REDIS.zinterstore(intersection_key, index_keys)
  REDIS.expire(intersection_key, 7200)

  data_hash_keys  = REDIS.zrevrange(intersection_key, 0, -1)
  matching_movies = REDIS.hmget(data_key, *data_hash_keys)

  matching_movies.map {|movie| JSON.parse(movie, symbolize_names: true)}
end
```

