require 'fileutils'
require 'tmpdir'

module RTeX

  # Utility class to manage the lifetime of a temporary directory in which 
  # LaTeX can do its processing
  #
  class Tempdir
    
    # Create a new temporary directory, yield for processing, then remove it.
    #
    #   RTeX::Tempdir.open do |tempdir|
    #     # Use newly created temporary directory
    #     # ...
    #   end
    #
    # When the block completes, the directory is removed.
    #
    # Arguments can be either an specific directory name,
    #
    #   RTeX::Tempdir.open("/tmp/somewhere") do ...
    #
    # or options to assist the generation of a randomly named unique directory,
    #
    #   RTeX::Tempdir.open(:parent_path => PARENT, :basename => BASENAME) do ...
    # 
    # which would result in a new directory 
    # "[PARENT]/rtex/[BASENAME]-[random hash]/" being created.
    # 
    # The default +:parent_path+ is +Dir.tmpdir", and +:basename+ 'rtex'.
    #
    def self.open(*args)
      tempdir = new(*args)
      tempdir.create!
      
      # Yield the path and wait for the block to finish
      result = yield tempdir
      
      # We don't remove the temporary directory when exceptions occur,
      # so that the source of the exception can be dubbed (logfile kept)
      tempdir.remove!
      result
    end
    
    # Manually control tempdir creation and removal. Accepts the same arguments
    # as +RTeX::Tempdir.open+, but the user must call +#create!+ and +#remove!+
    # themselves:
    #
    #   tempdir = RTeX::Tempdir.new
    #   tempdir.create!
    #   # Use the temporary directory
    #   # ...
    #   tempdir.remove!
    #
    def initialize(*args)
      options = args.last.is_a?(Hash) ? options.pop : {}
      specific_path = args.first
      
      if specific_path
        @path = specific_path
      else
        @parent_path = options[:parent_path] || Dir.tmpdir
        @basename = options[:basename] || 'rtex'
      end
    end
    
    def create!
      FileUtils.mkdir_p path
      @removed = false
      path
    end
    
    # Is the temporary directory present on the filesystem
    def exists?
      File.exists?(path)
    end
    
    # The filesystem location of the temporary directory
    def path
      @path ||= File.expand_path(File.join(@parent_path, 'rtex', "#{@basename}-#{self.class.uuid}"))
    end
    
    # Return the +#path+ for use in string expansion
    alias :to_s :path
    
    # Forcibly remove this temporary directory
    def remove!
      return false if @removed
      FileUtils.rm_rf path
      @removed = true
    end
    
    # Try using uuidgen, but if that doesn't work drop down to
    # a poor-man's UUID; timestamp, thread & object hashes
    # Note: I don't want to add any dependencies (so no UUID library)
    #
    def self.uuid
      if (result = `uuidgen`.strip rescue nil).empty?
        "#{Time.now.to_i}-#{Thread.current.hash}-#{hash}"
      else
        result
      end
    end
    
  end
end
