require 'net/http'
require 'stringio'
require 'fileutils'

class GitCloner
  PACK_OBJECT_TYPES = {
    1 => :commit,
    2 => :tree,
    3 => :blob,
    4 => :tag,
    6 => :obj_ofs_delta,
    7 => :obj_ref_delta
  }.freeze

  class << self
    def execute(args)
      git_repo, dir = args
      base_uri = URI(git_repo + '/')
      create_git_dir(dir)

      refs = discover_refs(base_uri)
      refs.each do |ref|
        pack_file_content = download_ref(base_uri, ref[:sha])
        results = unpack_content(pack_file_content)

        write_git_objects(results[:objects], dir)
        write_files(results[:objects], dir)

        puts "Procssed ref #{ref[:sha]}"
      rescue StandardError => e
        puts "Could not process ref #{ref[:sha]}, #{e.message}"
        next
      end
    end

    private

    def create_git_dir(dir)
      git_dir = File.join(Dir.pwd, dir, '.git')
      FileUtils.mkdir_p(File.join(git_dir, 'objects'))
      FileUtils.mkdir_p(File.join(git_dir, 'branches'))
      FileUtils.mkdir_p(File.join(git_dir, 'info'))
      FileUtils.mkdir_p(File.join(git_dir, 'logs'))
      FileUtils.mkdir_p(File.join(git_dir, 'refs'))
      FileUtils.mkdir_p(File.join(git_dir, 'hooks'))
      File.write(File.join(git_dir, 'HEAD'), 'ref: refs/heads/master')
    end

    def write_git_objects(results, dir)
      obj_dir = File.join(Dir.pwd, dir, '.git', 'objects')

      results.each do |result|
        hex_digest = result[:sha]

        git_object_dir = File.join(obj_dir, hex_digest[0..1])
        git_object_path = File.join(git_object_dir, hex_digest[2..])

        FileUtils.mkdir_p(git_object_dir)
        file_content = "#{result[:type]} #{result[:content].bytes.length}\0#{result[:content]}"
        File.write(git_object_path, Zlib::Deflate.deflate(file_content))
      end
    end

    def write_files(objects, dir)
      commits = objects.select { |obj| obj[:type] == :commit }
      objects_by_sha = objects.map { |o| [o[:sha], o] }.to_h

      commits.each do |commit|
        tree_entries = []

        commit[:content].split("\n").each do |line|
          tree_entries << line if line.start_with?('tree')
        end

        tree_entries.each do |entry|
          _, tree_sha = entry.split
          tree_obj = objects_by_sha[tree_sha]
          write_files_from_tree(tree_obj, dir, objects_by_sha)
        end
      end
    end

    def write_files_from_tree(object, dir, objects_by_sha)
      stream = StringIO.new(object[:content])

      while stream.pos < object[:content].bytes.length
        start = stream.pos
        length = 0
        length += 1 while stream.read(1) != "\0"

        stream.pos = start
        _mode, name = stream.read(length).split
        stream.pos += 1
        sha = stream.read(20).unpack1('H*')
        obj = objects_by_sha[sha]
        raise 'OBJECT NOT FOUND' unless obj

        path = File.join(dir, name)

        if obj[:type] == :tree
          FileUtils.mkdir_p(path)
          write_files_from_tree(obj, path, objects_by_sha)
        else
          File.write(path, obj[:content])
        end
      end

      stream.close
    end

    def discover_refs(base_uri)
      upload_pack_uri = URI.join(base_uri, 'info/refs?service=git-upload-pack')

      # TODO: Response streaming
      response = Net::HTTP.get_response(upload_pack_uri)
      res_header = response.body.bytes.first(5).pack('C*')
      raise 'Invalid Server Response' unless res_header.match?(/^[0-9a-f]{4}#/)

      raw_refs = response.body.split("\n")[1..]&.reject! { |l| l == '0000' }

      raw_refs.map do |ref|
        components = ref.split
        {
          sha: components.first[4..],
          name: components.last
        }
      end
    end

    def download_ref(base_uri, ref)
      upload_pack_uri = URI.join(base_uri, 'git-upload-pack')
      body = <<~BODY
        0032want #{ref}
        00000009done
      BODY

      response = Net::HTTP.post(upload_pack_uri, body, "Content-Type": 'application/x-git-upload-pack-request')
      response.body
    end

    def unpack_content(content)
      stream = StringIO.open(content)

      # Include 8 byte Ack
      raise 'Invalid Pack File' unless stream.read(12)&.end_with?('PACK')

      version_num = stream.read(4).unpack1('N')
      raise 'Invalid Version Num' unless [1, 2].include?(version_num)

      num_objects = stream.read(4).unpack1('N')
      objects = Array.new(num_objects) { extract_pack_object(stream) }
      apply_deltas(objects)

      {
        version: version_num,
        objects: objects
      }
    end

    def apply_deltas(objects)
      delt_objs = objects.select { |obj| deltified_type?(obj[:type]) }

      return if delt_objs.empty?

      base_objs_by_sha = objects.each_with_object({}) do |obj, hash|
        hash[obj[:sha]] = obj
      end

      delt_objs.each do |delta_obj|
        applied = apply_delta(delta_obj, base_objs_by_sha)
        next unless applied

        objects.delete(delta_obj)
        objects << applied
        base_objs_by_sha[applied[:sha]] = applied
      end
    end

    def apply_delta(delta_obj, base_obj_references)
      base_sha = delta_obj[:base_obj_ref]
      base_obj = base_obj_references[base_sha]

      if base_obj.nil?
        puts "no base obj found for ref #{base_sha}"
        return
      end

      stream = StringIO.new(delta_obj[:content])
      base_stream = StringIO.new(base_obj[:content])
      transform_stream = StringIO.new

      _source_length = extract_length(stream)
      _target_length = extract_length(stream)

      loop do
        instruction = stream.read(1)&.ord
        break if instruction.nil?

        instruction_type = instruction & 0b10000000 == 0b10000000 ? :copy : :insert

        if instruction_type == :copy
          length, offset = extract_copy_length_and_offset(instruction, stream)
          base_stream.pos = offset
          to_copy = base_stream.read(length)
          transform_stream.write(to_copy)
        else
          length = instruction & 0b01111111
          to_insert = stream.read(length)
          transform_stream.write(to_insert)
        end
      end

      transform_stream.pos = 0
      content = transform_stream.read

      {
        content: content,
        type: base_obj[:type],
        sha: hash_object(base_obj[:type].to_s, content)
      }
    end

    def extract_copy_length_and_offset(instruction, stream)
      @length_bitmasks ||= [0b01000000, 0b00100000, 0b00010000].reverse
      @offset_bitmasks ||= [0b00001000, 0b00000100, 0b00000010, 0b00000001].reverse

      offset = 0
      @offset_bitmasks.each_with_index do |mask, idx|
        next unless instruction & mask == mask

        offset |= (stream.read(1).ord << (8 * idx))
      end

      length = 0
      @length_bitmasks.each_with_index do |mask, idx|
        next unless instruction & mask == mask

        length |= (stream.read(1).ord << (8 * idx))
      end

      [length, offset]
    end

    def extract_pack_object(stream)
      current_byte = stream.read(1).ord
      raw_type = (current_byte & 0b01110000) >> 4
      type = PACK_OBJECT_TYPES[raw_type]

      raise "Invalid Pack Object Type: #{raw_type}" unless type

      stream.pos -= 1
      decompressed_length = extract_length(stream)

      if deltified_type?(type)
        extract_deltified_obj(stream, type, decompressed_length)
      else
        extract_non_deltified_obj(stream, type, decompressed_length)
      end
    end

    def extract_length(stream)
      current_byte = stream.read(1).ord
      length = (current_byte & 0b00001111)

      while current_byte & 0b10000000 == 0b10000000
        current_byte = stream.read(1).ord
        to_shift = to_shift.nil? ? 4 : to_shift + 7
        length = ((current_byte & 0b01111111) << to_shift) | length
      end

      length
    end

    def deltified_type?(type)
      %i[obj_ofs_delta obj_ref_delta].include?(type)
    end

    def extract_non_deltified_obj(stream, type, decompressed_length)
      content = decompress_content(stream, decompressed_length)
      sha = hash_object(type.to_s, content)

      {
        type: type,
        content: content,
        sha: sha
      }
    end

    def extract_deltified_obj(stream, type, decompressed_length)
      base_obj_ref = if type == :obj_ref_delta
                       stream.read(20).unpack1('H*')
                     else
                       stream.read(20)
                     end

      content = decompress_content(stream, decompressed_length)
      sha = hash_object(type.to_s, content)

      {
        type: type,
        base_obj_ref: base_obj_ref,
        content: content,
        sha: sha
      }
    end

    def decompress_content(stream, decompressed_length)
      start_pos = stream.pos
      inflator = Zlib::Inflate.new

      # TODO: Fix issue with length read for delitfied objs
      content = inflator.inflate(stream.read)
      stream.pos = start_pos + inflator.total_in
      inflator.close

      content
    end

    def hash_object(type, file_content)
      content = "#{type} #{file_content.bytes.length}\0#{file_content}"
      Digest::SHA1.hexdigest(content)
    end
  end
end
