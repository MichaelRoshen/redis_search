# Ordered Search Autocompletion With Redis

I spent the last weekend building a caching system for AnyGood using Redis to save API responses for certain amount of time. Since the next item on my TODO list was autocompletion for my search form I started googling around looking for solutions involving Redis. I stumbled upon two great posts examining this particular topic: The first one written by Salvatore Sanfilippo is a great explanation on how to use Redis for autocompletion and goes in great detail when explainin the algorithm. The second one by Pat Shaughnessy is a great help when explaining Sanfilippos algorithm and comparing it to Soulmate, "a tool to help solve the common problem of developing a fast autocomplete feature. It uses Redis's sorted sets to build an index of partially completed words and the corresponding top matching items, and provides a simple sinatra app to query them."

So I spent a good amount of time studying those articles and reading through the source code of Soulmate before I decided to write my own solution. Why? Because it was a rainy sunday afternoon, playing around with Redis is fun and I wanted to learn more about it. Plus: I wanted multiple phrase matching and search result ordering. Soulmate did all that and a bit more but just setting it up wouldn't have the same learning effect. And since I was out to play, I might as well have fun. So let's see how to this...
What it should do

Let's suppose we want autocompletion for our search form that not only returns a single value for each proposed item but also comes with some data that we can present. Also, let's go one step further and say that the search form should present the items available to the user in an ordered way, e.g. by popularity.

So when a user types into the search form, we want to to show him all the possible movies matching his search phrases. That means the first thing we've got to do is dump the data we want to present into Redis. Like Soulmate, we use a Redis hash here, where each movie has its own unique key. The key can be anything as long as it's unique. If you don't have unique IDs for your data, you could use MD5 to generate some. But let's suppose we do have an unique ID, dumping the data into Redis is pretty simple:

当一个用户在搜索框输入一些内容的时候，我们需要展示给用户和输入内容匹配的电影，这意味着我们第一件事要
做的就是把电影信息存放在redis中，每个电影有它唯一的主键，可以使用MD5自己生成，现在假设我们已经有了
唯一的主键，我们现在有十部电影：

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

通过HSET将电影信息保存到hash，以moviesearch:data作为key，通过ruby我们可以轻松的在redis
和ruby之间进行转换。

require 'json'
# Before dumping to Redis:
{name: 'Kill Bill', year: 2003}.to_json
# => "{\"name\":\"Kill Bill\",\"year\":2003}"
# After retrieving from Redis:
JSON.parse("{\"name\":\"Kill Bill\",\"year\":2003}")
# => {"name"=>"Kill Bill", "year"=>2003}

顺便说一下，这里使用redis-rb作为Ruby连接Redis的工具，好，现在我们已经把电影存到Redis中了，下面看一下
如何查找？

通常，我们在搜索一个电影名字的时候，我们需要输入电影的名字到搜索框，而我们要做的是当用户还没有完全输入完电影名字的时候，展示于之匹配的几个电影供其选择，也就是自动补全，比如要搜索hello的时候，可以通过
输入he, hel, hell, hello自动补全

People are most likely trying to search for a movie by starting to type its name into the input field. And we want to show them the matching movies before they're even finished typing the whole name, right? That's why we're talking about autocompletion here. That means we need an association between word prefixes and the movies. If someone were to type in The Dar we want to show The Dark Knight and The Dark Knight Rises as possible search terms. Long story short: we need to get the prefixes of every movie we just dumped in our moviesearch:data hash. For that I'm using a simple method, which is heavily based on the one Sanfilippo uses in his example script:

def prefixes_for(string)
  prefixes = []
  words    = string.downcase.split(' ')

  words.each do |word|
  (1..word.length).each {|i| prefixes << word[0...i] unless i == 1}
  end

  prefixes
end

The movie with the name The Dark Knight will result in the following prefixes: ```ruby prefixes_for('The Dark Knight')
=> ["th", "the", "da", "dar", "dark", "kn", "kni", "knig", "knigh", "knight"]

And *The Dark Knight Rises* will result in the following prefixes:
```ruby
prefixes_for('The Dark Knight Rises')
# => ["th", "the", "da", "dar", "dark", "kn", "kni", "knig", "knigh", "knight", "ri", "ris", "rise", "rises"]

We need to generate those prefixes for every movie we want to use in our search autocompletion and so I use a minimum prefix length of two characters here, because using one character prefixes is a lot of overhead for search completion where most people are going to type in more than one character.

(Of course it's entirely possible to not only use prefixes, but use every range of characters from any position in the word. Instead of using fi, fis, fish for Fish, we could use fi, fis, fish, is, ish, sh. But people are more likely to type the beginning of a word, I guess.)
Save those prefixes to sorted sets!

Redis uses sorted sets as a list of unique strings that can be ranked by a score. For now, we will ignore the score and just use this as a set where every entry is unique and trying to add one with the same name won't result in a new entry. So let's create a sorted set for every prefix. This set will include the key of the movies in which the prefix occurs and the pattern for those keys is the one Soulmate uses: moviesearch:index:$PREFIX.

In order to associate the movie The Dark Knight with its prefixes we need to do the following for every prefix:

ZADD moviesearch:index:dar 0 9

As you might have guessed, the prefix here is dar. The next number in this command is the score the member of this sorted set will have, but as I said, ignore this for now and keep in mind that the 9 is the key of our moviesearch:data hash pointing to the The Dark Knight. So we need to associate all prefixes of every moviename with its key in the moviesearch:data hash. Written in Ruby a method doing exactly that would look like this:

def add_movie(movie_name, data_hash_key)
  prefixes = prefixes_for(movie_name)

  prefixes.each do |prefix|
    REDIS.zadd("moviesearch:index:#{prefix}", 0, data_hash_key)
  end
end

That's pretty simple, isn't it? The method takes two arguments: the name of the movie and the key of the moviesearch:data hash pointing to its data. After using that method for all the movies we added to our data hash, we have a lot of sorted sets with its members being the keys for our data hash. That means, after adding The Dark Knight and The Dark Knight Rises the moviesearch:index:dark set has two members: 9 and 10. So, what does that give us?

Let's imagine a user is visiting our website and typing dar into the input field of the search form.

We now get all the entries in moviesearch:index:dar, which are the keys of our moviesearch:data hash. The sorted set with the key moviesearch:index:dar contains 9 and 10 as members. With those numbers we can now just fetch all the hash entries with these as key and present them to the user. But let's see how that works.
Matching more than one word using Redis' ZINTERSTORE

If we want to get all the entries for moviesearch:index:ki we use the ZRANGE command provided by Redis:

ZRANGE moviesearch:index:dar 0 -1

Starting from the first element (0 since Redis starts indexing with 0) and going to the last (-1) we get the hash keys for movies whose names contain the prefix 'dar':

$ redis-cli ZRANGE moviesearch:index:dar 0 -1
1) "9"
2) "10"

And now, let's fetch all the entries from our moviesearch:data with those keys:

$ redis-cli HMGET moviesearch:data 9 10
1) "{\"name\":\"The Dark Knight Rises\",\"year\":2008}"
2) "{\"name\":\"The Dark Knight\",\"year\":2008}"

Instead of using HGET we use HMGET to fetch multiple hash entries. That's quite neat! Now we have all the movies containing a word that starts with 'dar'. And we could present those to the user, who is typing and waiting for suggestions. Let's go one step further though:

Let's suppose a user has typed ki bi into our search form. We now want to present him Kill Bill, Kill Bill 2, Kilts for Bill as suggestions, but not Killer Elite and not King Kong. That means we need to find a movie containing both those prefixes in its name and not only one of them. And this is exactly where Redis' ZINTERSTORE comes out to play.

ZINTERSTORE creates a new sorted with a given key containing all the members occuring in the sets passed to it. Let's use it to create a temporary set containing the hash keys of the movies having 'ki bi' in their names:

$ redis-cli ZINTERSTORE moviesearch:index:ki|bi 2 moviesearch:index:ki moviesearch:index:bi

What happens here? ZINTERSTORE looks up which members are in both moviesearch:index:ki and moviesearch:index:bi and creates a new sorted set with the key moviesearch:index:ki|bi containing those members. The pattern for this key is also from Soulmate: dig through the code as there are lots of great ideas! Now we can use the ZRANGE command again and see which movies contain those prefixes:

$ redis-cli ZRANGE 'moviesearch:index:ki|bi'
1) "1"
2) "4"
3) "5"

And those are exactly the keys pointing to Kill Bill, Kill Bill 2 and Kilts For Bill in the moviesearch:data hash! Great! All we have to do now is use HMGET to get the data for those keys from the hash and present them to the user.
Score & Popularity

Until now we ignored the score of our sorted sets. But let's say all our users are looking up Kill Bill by typing in Ki Bi and hitting enter. Let's also assume there are a lot more users looking up Kill Bill than there are people interested in Kindergarten Cop (as weird as this assumption may sound, bear with me here). Remember when we associated the movies with the prefixes? We did this, using 0 as the score:

ZADD moviesearch:index:ki 0 1

Now, everytime a person looks up Kill Bill instead of Kindergarten Cop we can increment the score of the 1 entry (pointing to Kill Bill) in the moviesearch:index:ki set (and all the other sets containing 1) using ZINCRBY. ZINCRBY increments the score of a given member in a given set by a given value. In order to sort our results by popularity we could increment the score of a given movie everytime a user looks that movie up. A simple method for doing this would probably look like this:

def incr_score_for(movie_name, data_hash_key)
  prefixes    = prefixes_for(movie_name)

  prefixes.each do |prefix|
    REDIS.zincrby(index_key_for(prefix), 1, data_hash_key)
  end
end

We take every prefix occuring in the movie name and increment the score of the member pointing to the movie's data in the moviesearch:data hash.

Now, before thinking about scores of set members we used ZRANGE to get the members of a given set. Working with scores now, the next time we try to match a movie with the given prefixes we'll use ZREVRANGE to return the matching hash keys ordered by their respective score. The following should then give us Kill Bill at the top after we incremented the score for this movie every time a user looks it up.

ZREVRANGE  moviesearch:index:ki 0 -1

Using ZREVRANGE, ZUNIONSTORE and HMGET combined we can write a Ruby method to look up movies matching the passed prefixes and order them by score:

def find_by_prefixes(prefixes)
  intersection_key = index_key_for(prefixes)
  index_keys       = prefixes.map {|prefix| index_key_for(prefix)}

  REDIS.zinterstore(intersection_key, index_keys)
  REDIS.expire(intersection_key, 7200)

  data_hash_keys  = REDIS.zrevrange(intersection_key, 0, -1)
  matching_movies = REDIS.hmget(data_key, *data_hash_keys)

  matching_movies.map {|movie| JSON.parse(movie, symbolize_names: true)}
end

This method takes an array of prefixes as argument, creating the index keys for them, then it creates a temporary sorted set using ZINTERSTORE (EXPIRE tells Redis to delete a given key after the specified time in seconds) containing the data hash keys pointing to the movies. After that ZREVRANGE gives us all the members of this set ordered by their score and finally HMGET is used to get the data for all the matching keys from the moviesearch:data hash. There are a couple of helper methods involved, but it should still be pretty clear what happens. If not, look at the code of the whole MovieMatcher class I use in Anygood here.

So everything combined we use Redis hashes to save our data, sorted sets for every prefix whose members point at our movies in the hash and in order to find movies containing multiple prefixes we use ZINTERSTORE as a cache to point us to the movies containing both. And now we've got search autocompletion presenting ordered results to the user matching multiple phrases!

If you want to dig deeper, please read through the source code of Soulmate and study those two articles mentioned in the first paragraph. They both do a great job at explaining what exactly is going on here and why to use sorted sets and the other data types as we do
