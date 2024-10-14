require 'zlib'
require 'digest'
require_relative 'git_cloner'

def main
  command = ARGV[0]&.downcase&.gsub('-', '_')

  raise 'Command Not Provided' unless command

  raise "Unknown command #{command}" unless %w[init cat_file hash_object ls_tree write_tree commit_tree
                                               clone].include?(command)

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

def ls_tree(args)
  *options, tree_sha = args

  raise ArgumentError, 'Invalid SHA' unless tree_sha&.length == 40

  path = ".git/objects/#{tree_sha[0..1]}/#{tree_sha[2..]}"

  raise ArgumentError, 'Invalid SHA' unless File.exist?(path)

  # TODO: Buffered Read
  buffer = Zlib::Inflate.inflate(File.read(path)).bytes

  header_length = buffer.find_index(0x00) + 1
  header = buffer.shift(header_length)
  _, expected_size = header.pack('C*').strip.split(' ')

  raise ArgumentError, 'Invalid content' unless expected_size.to_i == buffer.length

  tree_objects = []

  until buffer.empty?
    entry_length = buffer.find_index(0x00) + 1
    entry = buffer.shift(entry_length).pack('C*')
    mode, name = entry.split(' ').map(&:strip)
    sha_hash = Digest::SHA1.hexdigest(buffer.shift(20).pack('C*'))

    tree_objects << {
      mode: mode.rjust(6, '0'),
      type: mode == '40000' ? 'tree' : 'blob',
      sha_hash: sha_hash,
      name: name
    }
  end

  if options.include?('--name-only')
    tree_objects.each { |obj| puts obj[:name] }
    return
  end

  tree_objects.each do |obj|
    puts "#{obj.values[0..2].join("\s")}\t#{obj.values.last}"
  end
end

def commit_tree(args)
  tree_sha = args.shift
  until args.empty?
    option, val = args.shift(2)
    if option == '-p'
      commit_sha = val
    elsif option == '-m'
      message = val.lstrip
    end
  end

  raise ArgumentError, 'Invalid Args' unless tree_sha && commit_sha && message

  content = "tree #{tree_sha}
  parent #{commit_sha}
  author Author <author@email.com> #{Time.now.to_i} +0000
  committer Author <author@email.com> #{Time.now.to_i} +0000

#{message}
"

  puts process_content(content, 'commit')[:hex_digest]
end

def write_tree(_args)
  puts process_dir(Dir.pwd)[:hex_digest]
end

def clone(args)
  GitCloner.execute(args)
end

def process_dir(dirname)
  tree_entries = []

  Dir.entries(dirname).sort.each do |entry|
    path = "#{dirname}/#{entry}"
    is_dir = Dir.exist?(path)

    next if ['.', '..', '.git'].include?(entry)

    entry_mode = is_dir ? '40000' : '100644'

    entry_content = if is_dir
                      process_dir(path)
                    else
                      process_content(File.read(path), 'blob')
                    end

    tree_entries << "#{entry_mode} #{entry}\0#{entry_content[:binary_digest]}"
  end

  process_content(tree_entries.join(''), 'tree')
end

def process_content(content, header_type)
  entry_content = "#{header_type} #{content.bytes.length}\0#{content}"
  hex_digest = Digest::SHA1.hexdigest(entry_content)
  binary_digest = Digest::SHA1.digest(entry_content)

  git_object_dir = File.join(Dir.pwd, '.git', 'objects', hex_digest[0..1])

  Dir.mkdir(git_object_dir) unless Dir.exist?(git_object_dir)

  git_object_path = File.join(git_object_dir, hex_digest[2..])

  File.write(git_object_path, Zlib::Deflate.deflate(entry_content))

  {
    hex_digest: hex_digest,
    binary_digest: binary_digest
  }
end

main
