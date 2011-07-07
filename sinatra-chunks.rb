require 'sinatra'
require 'raw_recognizer'
require 'uuidtools'
require 'json'
require 'iconv'
require 'set'
require 'yaml'
require 'open-uri'
require 'md5'

configure do
  $config = {}
  $config = YAML.load_file('conf.yaml')
  RECOGNIZER = Recognizer.new($config)
  
  fsg_config = $config.clone
  fsg_config['pocketsphinx'].delete('lm')
  # we need to load dummy FSG to avoid segfault later
  fsg_config['pocketsphinx']['fsg'] = 'dummy.fsg'
  FSG_RECOGNIZER = Recognizer.new(fsg_config)
  
  $prettifier = nil
  if $config['prettifier'] != nil
    $prettifier = IO.popen($config['prettifier'], mode="r+")
  end
  disable :show_exceptions
  
  $outdir = nil
  begin
    $outdir = $config.fetch('logging', {}).fetch('request-debug', '')
  rescue
  end
  
  CHUNK_SIZE = 4*1024
end

post '/recognize' do
  do_post()
end

put '/recognize' do
  do_post()
end

put '/recognize/*' do
  do_post()
end


def do_post()
  id = SecureRandom.hex
  puts "Request ID: " + id
  req = Rack::Request.new(env)
  
  puts headers
  
  lm_name = req.params['lm']
  puts "Client requests to use lm=#{lm_name}"
  
  if lm_name != nil and lm_name != ""  
    puts "Using FSG recognizer"  
    @use_rec = FSG_RECOGNIZER
    fsg_file = fsg_file_from_url(lm_name)
    if File.exists? fsg_file
      @use_rec.set_fsg_file(fsg_file)
    else
      raise IOError, "Language model #{lm_name} not available. Use /fetch-jsgf API call to upload it to the server"
    end
  else
    puts "Using ngram recognizer"
    @use_rec = RECOGNIZER
  end
  
  if $outdir != nil
     File.open("#{$outdir}/#{id}.info", 'w') { |f|
       req.env.select{ |k,v|
          f.write "#{k}: #{v}\n"
       }
    }
  end
  puts "User agent: " + req.user_agent
  puts "Parsing content type " + req.content_type
  caps_str = content_type_to_caps(req.content_type)
  puts "CAPS string is " + caps_str
  @use_rec.clear(id, caps_str)
  
  length = 0
  
  left_over = ""
  req.body.each do |chunk|
    chunk_to_rec = left_over + chunk
    if chunk_to_rec.length > CHUNK_SIZE
      chunk_to_send = chunk_to_rec[0..(chunk_to_rec.length / 2) * 2 - 1]
      @use_rec.feed_data(chunk_to_send)
      left_over = chunk_to_rec[chunk_to_send.length .. -1]
    else
      left_over = chunk_to_rec
    end
    length += chunk.size
  end
  @use_rec.feed_data(left_over)
    
  
  puts "Got feed end"
  if length > 0
    @use_rec.feed_end()
    result = @use_rec.wait_final_result()
    puts "RESULT:" + result
    # only prettify results decoded using ngram
    if @use_rec == RECOGNIZER
      result = prettify(result)
      puts "PRETTY RESULT:" + result                          
    end
    result = Iconv.iconv('utf-8', 'latin1', result)[0]
    headers "Content-Type" => "application/json; charset=utf-8", "Content-Disposition" => "attachment"
    JSON.pretty_generate({:status => 0, :id => id, :hypotheses => [:utterance => result]})
  else
    @use_rec.stop
    headers "Content-Type" => "application/json; charset=utf-8", "Content-Disposition" => "attachment"
    JSON.pretty_generate({:status => 0, :id => id, :hypotheses => [:utterance => ""]})
  end
end

error do
    puts "Error: " + env['sinatra.error']
    if @use_rec.recognizing
      puts "Trying to clear recognizer.."
      @use_rec.stop
      puts "Cleared recognizer"
    end
    'Sorry, failed to process request. Reason: ' + env['sinatra.error'] + "\n"
end

def content_type_to_caps(content_type)
  if not content_type
    content_type = "audio/x-raw-int"
    return "audio/x-raw-int,rate=16000,channels=1,signed=true,endianness=1234,depth=16,width=16"
  end
  parts = content_type.split(%r{[,; ]})
  result = ""
  allowed_types = Set.new ["audio/x-flac", "audio/x-raw-int", "application/ogg", "audio/mpeg", "audio/x-wav",  ]
  if allowed_types.include? parts[0]
    result = parts[0]
    if parts[0] == "audio/x-raw-int"
      attributes = {"rate"=>"16000", "channels"=>"1", "signed"=>"true", "endianness"=>"1234", "depth"=>"16", "width"=>"16"}
      user_attributes = Hash[*parts[1..-1].map{|s| s.split('=', 2) }.flatten]
      attributes.merge!(user_attributes)
      result += ", " + attributes.map{|k,v| "#{k}=#{v}"}.join(", ")
    end
    return result
  else
    raise IOError, "Unsupported content type: #{parts[0]}. Supported types are: " + allowed_types.to_a.join(", ") + "." 
  end
end

def prettify(hyp)
  if $prettifier != nil
    $prettifier.puts hyp
    $prettifier.flush
    return $prettifier.gets.strip
  end
  return hyp
end

get '/fetch-jsgf' do 
  url = req.params['lm']  
  puts "Fetching JSGF grammar from #{url}"
  digest = MD5.hexdigest url
  content = open(url).read
  jsgf_file =  $config.fetch('grammar-dir', 'user_grammars') + "/#{digest}.jsgf"
  fsg_file =  fsg_file_from_url(url)
  File.open(jsgf_file, 'w') { |f|
    f.write(content)
  }
  puts "Converting to FSG"
  `sphinx_jsgf2fsg -jsgf #{jsgf_file} -fsg #{fsg_file}`
  if $? != 0
    raise "Failed to convert JSGF to FSG" 
  end
end

def fsg_file_from_url(url)
  digest = MD5.hexdigest url
  return $config.fetch('grammar-dir', 'user_grammars') + "/#{digest}.fsg"
end

