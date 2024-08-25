require 'zlib'
require 'digest'

def main
  command = ARGV[0]&.downcase&.gsub('-', '_')

  raise 'Command Not Provided' unless command

  raise "Unknown command #{command}" unless %w[init cat_file hash_object].include?(command)

  begin
    command_args = ARGV[1..]
    send(command.to_sym, command_args)
  rescue ArgumentError => e
    puts e.message
  end
end

def init(_args)
  Dir.mkdir('.git')
  Dir.mkdir('.git/objects')
  Dir.mkdir('.git/refs')
  File.write('.git/HEAD', "ref: refs/heads/main\n")
  puts 'Initialized git directory'
end

def cat_file(args)
  raise ArgumentError, 'Args must be provided' unless args.is_a?(Array)

  *options, obj = args

  raise ArgumentError, "Not a valid object name #{obj}" unless obj&.length == 40

  raw_file = nil

  begin
    dir = obj[0..1]
    filename = obj[2..]
    path = ".git/objects/#{dir}/#{filename}"
    raw_file = File.read(path)
  rescue StandardError
    raise ArgumentError, "Not a valid object name #{obj}"
  end

  obj = Zlib::Inflate.inflate(raw_file)
  _header, content = obj.split("\x00", 2)

  return unless options.include?('-p')

  print content
end

def hash_object(args)
  *options, filename = args

  file_content = File.read(filename)
  content = "blob #{file_content.bytes.length}\0#{file_content}"
  compressed_content = Zlib::Deflate.deflate(content)
  hash = Digest::SHA1.hexdigest(content)

  if options.include?('-w')
    dir = ".git/objects/#{hash[0..1]}"
    Dir.mkdir(dir) unless Dir.exist?(dir)
    File.write("#{dir}/#{hash[2..]}", compressed_content)
  end

  puts hash
end

main
