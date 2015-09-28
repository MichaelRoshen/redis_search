require 'redis'
require 'json'


$redis = Redis.new({:host => '127.0.0.1', :port => 6379})
records = [
	{id: 1, name: 'Kill Bill', year: 2003},
	{id: 2, name: 'King Kong',year: 2005},
	{id: 3, name: 'Killer Elite',year: 2011},
	{id: 4, name: 'Kilts for Bill',year: 2027},
	{id: 5, name: 'Kill Bill 2',year: 2004},
	{id: 6, name: 'Kids',year: 1995},
	{id: 7, name: 'Kindergarten Cop',year: 1990},
	{id: 8, name: 'The Green Mile',year: 1999},
	{id: 9, name: 'The Dark Knight',year: 2008},
	{id: 10, name: 'The Dark Knight Rises',year: 2012}
]

def data_key
  "moviesearch:data"
end

def index_key
  "moviesearch:index"
end


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

def add_movie(movie_name, data_hash_key)
  prefixes = prefixes_for(movie_name)
  prefixes.each do |prefix|
    $redis.zadd("#{index_key}:#{prefix}", 0, data_hash_key)
  end
end

def index_key_for(prefix)
  "#{index_key}:#{prefix}"
end

def incr_score_for(movie_name, data_hash_key)
  prefixes    = prefixes_for(movie_name)

  prefixes.each do |prefix|
    $redis.zincrby(index_key_for(prefix), 1, data_hash_key)
  end
end

def find_by_prefixes(prefixes)
  intersection_key = index_key_for(prefixes)
  index_keys       = prefixes.map {|prefix| index_key_for(prefix)}

  $redis.zinterstore(intersection_key, index_keys)
  $redis.expire(intersection_key, 7200)

  data_hash_keys  = $redis.zrevrange(intersection_key, 0, -1)
  matching_movies = $redis.hmget(data_key, *data_hash_keys)

  matching_movies.map {|movie| JSON.parse(movie, symbolize_names: true)}
end



def add_search_data(records, clear = false)
  $redis.del(data_key) if clear
    records.each do |record|
      $redis.hset(data_key, record[:id], record.to_json)
  end
end

def add_index_data(records)
  records.each do |record|
    prefixes = prefixes_for(record[:name])
    add_movie(record[:name], record[:id])
  end
end

def find_by_prefixes(prefixes)
  intersection_key = index_key_for(prefixes)
  index_keys       = prefixes.map {|prefix| index_key_for(prefix)}

  $redis.zinterstore(intersection_key, index_keys)
  $redis.expire(intersection_key, 7200)

  data_hash_keys  = $redis.zrevrange(intersection_key, 0, -1)
  matching_movies = $redis.hmget(data_key, *data_hash_keys)

  matching_movies.map {|movie| JSON.parse(movie, symbolize_names: true)}
end

add_search_data(records)
add_index_data(records)
find_by_prefixes(['kil'])
find_by_prefixes(['dar'])

incr_score_for("Kill Bill 2", 5)
find_by_prefixes(['ki','bi'])






