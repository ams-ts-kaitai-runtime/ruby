require 'stringio'

module Kaitai
module Struct

VERSION = '0.4'

class Struct

  def initialize(_io, _parent = nil, _root = self)
    @_io = _io
    @_parent = _parent
    @_root = _root
  end

  def self.from_file(filename)
    self.new(Stream.open(filename))
  end

  ##
  # Implementation of `inspect` to aid debugging (at the very least,
  # to aid exception raising) for KS-based classes. This one uses a
  # bit terser syntax than Ruby's default one, purposely skips any
  # internal fields (i.e. starting with `_`, such as `_io`, `_parent`
  # and `_root`) to reduce confusion, and does no recursivity tracking
  # (as proper general-purpose `inspect` implementation should do)
  # because there are no endless recursion in KS-based classes by
  # design (except for already mentioned internal navigation
  # variables).
  def inspect
    vars = []
    instance_variables.each { |nsym|
      nstr = nsym.to_s

      # skip all internal variables
      next if nstr[0..1] == '@_'

      # strip mandatory `@` at the beginning of the name for brevity
      nstr = nstr[1..-1]

      nvalue = instance_variable_get(nsym).inspect

      vars << "#{nstr}=#{nvalue}"
    }

    "#{self.class}(#{vars.join(' ')})"
  end

  attr_reader :_io
end

class Stream
  class UnexpectedDataError < Exception
    def initialize(actual, expected)
      super("Unexpected fixed contents: got #{Stream.format_hex(actual)}, was waiting for #{Stream.format_hex(expected)}")
      @actual = actual
      @expected = expected
    end
  end

  def initialize(arg)
    if arg.is_a?(String)
      @_io = StringIO.new(arg)
    elsif arg.is_a?(IO)
      @_io = arg
    else
      raise TypeError.new('can be initialized with IO or String only')
    end
  end

  def self.open(filename)
    self.new(File.open(filename, 'rb:ASCII-8BIT'))
  end

  # Test endianness of the platform
  @@big_endian = [0x0102].pack('s') == [0x0102].pack('n')

  # ========================================================================
  # Stream positioning
  # ========================================================================

  def eof?; @_io.eof?; end
  def seek(x); @_io.seek(x); end
  def pos; @_io.pos; end

  # ========================================================================
  # Integer numbers
  # ========================================================================

  # ------------------------------------------------------------------------
  # Signed
  # ------------------------------------------------------------------------

  def read_s1
    read_bytes(1).unpack('c')[0]
  end

  # ........................................................................
  # Big-endian
  # ........................................................................

  def read_s2be
    to_signed(read_u2be, SIGN_MASK_16)
  end

  def read_s4be
    to_signed(read_u4be, SIGN_MASK_32)
  end

  if @@big_endian
    def read_s8be
      read_bytes(8).unpack('q')[0]
    end
  else
    def read_s8be
      to_signed(read_u8be, SIGN_MASK_64)
    end
  end

  # ........................................................................
  # Little-endian
  # ........................................................................

  def read_s2le
    to_signed(read_u2le, SIGN_MASK_16)
  end

  def read_s4le
    to_signed(read_u4le, SIGN_MASK_32)
  end

  unless @@big_endian
    def read_s8le
      read_bytes(8).unpack('q')[0]
    end
  else
    def read_s8le
      to_signed(read_u8le, SIGN_MASK_64)
    end
  end

  # ------------------------------------------------------------------------
  # Unsigned
  # ------------------------------------------------------------------------

  def read_u1
    read_bytes(1).unpack('C')[0]
  end

  # ........................................................................
  # Big-endian
  # ........................................................................

  def read_u2be
    read_bytes(2).unpack('n')[0]
  end

  def read_u4be
    read_bytes(4).unpack('N')[0]
  end

  if @@big_endian
    def read_u8be
      read_bytes(8).unpack('Q')[0]
    end
  else
    def read_u8be
      a, b = read_bytes(8).unpack('NN')
      (a << 32) + b
    end
  end

  # ........................................................................
  # Little-endian
  # ........................................................................

  def read_u2le
    read_bytes(2).unpack('v')[0]
  end

  def read_u4le
    read_bytes(4).unpack('V')[0]
  end

  unless @@big_endian
    def read_u8le
      read_bytes(8).unpack('Q')[0]
    end
  else
    def read_u8le
      a, b = read_bytes(8).unpack('VV')
      (b << 32) + a
    end
  end

  # ========================================================================
  # Floating point numbers
  # ========================================================================

  # ------------------------------------------------------------------------
  # Big-endian
  # ------------------------------------------------------------------------

  def read_f4be
    read_bytes(4).unpack('g')[0]
  end

  def read_f8be
    read_bytes(8).unpack('G')[0]
  end

  # ------------------------------------------------------------------------
  # Little-endian
  # ------------------------------------------------------------------------

  def read_f4le
    read_bytes(4).unpack('e')[0]
  end

  def read_f8le
    read_bytes(8).unpack('E')[0]
  end

  # ========================================================================
  # Byte arrays
  # ========================================================================

  def read_bytes(n)
    r = @_io.read(n)
    if r
      rl = r.bytesize
    else
      rl = 0
    end
    raise EOFError.new("attempted to read #{n} bytes, got only #{rl}") if rl < n
    r
  end

  def read_bytes_full
    @_io.read
  end

  def ensure_fixed_contents(size, expected)
    buf = @_io.read(size)
    actual = buf.bytes
    if actual != expected
      raise UnexpectedDataError.new(actual, expected)
    end
    buf
  end

  # ========================================================================
  # Strings
  # ========================================================================

  def read_str_eos(encoding)
    read_bytes_full.force_encoding(encoding)
  end

  def read_str_byte_limit(byte_size, encoding)
    read_bytes(byte_size).force_encoding(encoding)
  end

  def read_strz(encoding, term, include_term, consume_term, eos_error)
    r = ''
    loop {
      if @_io.eof?
        if eos_error
          raise EOFError.new("end of stream reached, but no terminator #{term} found")
        else
          return r.force_encoding(encoding)
        end
      end
      c = @_io.getc
      if c.ord == term
        r << c if include_term
        @_io.seek(@_io.pos - 1) unless consume_term
        return r.force_encoding(encoding)
      end
      r << c
    }
  end

  # ========================================================================
  # Byte array processing
  # ========================================================================

  def process_xor_one(data, key)
    data.bytes.map { |x| x ^ key }.pack('C*')
  end

  def process_xor_many(data, key)
    kb = key.bytes
    kl = kb.size
    ki = 0
    data.bytes.map { |x|
      r = x ^ kb[ki]
      ki += 1
      ki = 0 if ki >= kl
      r
    }.pack('C*')
  end

  def process_rotate_left(data, amount, group_size)
    raise NotImplementedError.new("unable to rotate group #{group_size} bytes yet") unless group_size == 1

    mask = group_size * 8 - 1
    anti_amount = -amount & mask

    # NB: actually, left bit shift (<<) in Ruby would have required
    # truncation to type_bits size (i.e. something like "& 0xff" for
    # group_size == 8), but we can skip this one, because later these
    # number would be packed with Array#pack, which will do truncation
    # anyway

    data.bytes.map { |x| (x << amount) | (x >> anti_amount) }.pack('C*')
  end

  # ========================================================================

  private
  SIGN_MASK_16 = (1 << (16 - 1))
  SIGN_MASK_32 = (1 << (32 - 1))
  SIGN_MASK_64 = (1 << (64 - 1))

  def to_signed(x, mask)
    (x & ~mask) - (x & mask)
  end

  def self.format_hex(arr)
    arr.map { |x| sprintf('%02X', x) }.join(' ')
  end
end

end
end
