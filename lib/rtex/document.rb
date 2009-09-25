require 'erb'
require 'escaping'
require 'tempdir'

module RTeX
  class Document
    extend Escaping
    
    class FilterError < ::StandardError; end
    class GenerationError < ::StandardError; end
    class ExecutableNotFoundError < ::StandardError; end
    
    # Create a new +RTeX::Document+. A temporary directory will be created
    # for the lifetime of the document, and then destroyed at the end of the block.
    #
    #   RTeX::Document.create(source, :processor => "xelatex") do |document|
    #     puts "working in #{document.tempdir}"
    #
    #     document.to_pdf do |filename|
    #       # process PDF file
    #       # ...
    #     end
    #   end
    #
    # Options passed to +#create+ are the same as those for +#new+.
    #
    # To specify which temporary directory should be created for processing the
    # document, set +:tempdir+.
    #
    def self.create(content, options={})
      Tempdir.open(options[:tempdir]) do |dir|
        doc = Document.new(content, options.merge(:tempdir => dir))
        yield doc
      end
    end
    
    # Create a new +RTeX::Document+ in either the current directory (default) 
    # or a specified, pre-existing directory.
    #
    # The +content+ parameter should contain the document source.
    #
    # The +options+ hash may contain:
    # [+:processor+] Executable with which to output the document 
    #                (default: 'pdflatex')
    # [+:preprocessor+] Executable to use during preprocessing (particularly 
    #                   for longer documents containing a table-of-contents or 
    #                   bibliography section (default: 'latex')
    # [+:preprocess+] Either a boolean specifying whether to preprocess the 
    #                 input file(s), or an integer for the number of times to 
    #                 preprocess (default: false / 0)
    # [+:tmpdir+] Location of temporary directory (default: +Dir.getwd+)
    # [+:shell_redirect+] Option redirection for shell output, 
    #                     e.g. +"> /dev/null 2>&1"+ (default: +nil+).
    # [+:command_prefix+] String (or array) of environment variable settings
    #                     for the +:processor+ and +:preprocessor+ commands.
    #
    def initialize(content, options={})
      @options = self.class.options.merge(options)
      if @options[:processed]
        @source = content
      else
        @erb = ERB.new(content)
      end
    end
    
    # Get the compiled source for the entire document
    def source(binding=nil) #:nodoc:
      @source ||= wrap_in_layout do
        filter @erb.result(binding)
      end
    end
    
    # Process through defined filter
    def filter(text) #:nodoc:
      return text unless @options[:filter]
      if (process = RTeX.filters[@options[:filter]])
        process[text]
      else
        raise FilterError, "No `#{@options[:filter]}' filter"
      end
    end
    
    # Wrap content in optional layout
    def wrap_in_layout #:nodoc:
      if @options[:layout]
        ERB.new(@options[:layout]).result(binding)
      else
        yield
      end
    end
    
    # Generate PDF output:
    #
    #   to_pdf # => PDF in a String
    #   to_pdf { |filename| ... }
    #
    def to_pdf(binding=nil, &file_handler)
      process_pdf_from(source(binding), &file_handler)
    end
    
    def processor #:nodoc:
      @processor ||= check_path_for @options[:processor]
    end
    
    def preprocessor #:nodoc:
      @preprocessor ||= check_path_for @options[:preprocessor]
    end
    
    def system_path #:nodoc:
      ENV['PATH']
    end
    
    def self.options #:nodoc:
      @options ||= {
        :preprocessor => 'latex',
        :preprocess => false,
        :processor => 'pdflatex',
        :shell_redirect => nil,
        :tex_inputs => nil,
        :command_prefix => nil,
        :tempdir => Dir.getwd # Current directory unless otherwise set
      }
    end
    
    attr_reader :options
    
  private
    
    # Verify existence of executable in search path
    def check_path_for(command)
      unless FileTest.executable?(command) || system_path.split(":").any?{ |path| FileTest.executable?(File.join(path, command))}
        raise ExecutableNotFoundError, command
      end
      command
    end
    
    # Basic processing
    #
    # The general call sequence is:
    #   #to_pdf (from user) => #source (ruby compile) => #process_pdf_from => #prepare => #preprocess! => #process! => #verify! => return as string or output filename
    #
    def process_pdf_from(input, &file_handler)
      prepare input
      if generating?
        preprocess_count.times { preprocess! }
        process!
        verify!
      end
      if file_handler
        yield result_file
      else
        result_as_string
      end
    end
    
    # Save the Ruby-compiled document source to a file
    # It is then ready for LaTeX to compile it into a PDF
    #
    def prepare(input)
      File.open(source_file, 'wb') { |f| f.puts input }
    end
    
    def command(executable)
      "#{environment_vars}#{executable} --output-directory='#{tempdir}' --interaction=nonstopmode '#{File.basename(source_file)}' #{@options[:shell_redirect]}"
    end
    
    # Run LaTeX pre-processing step on the source file
    def preprocess!
      unless `#{command(preprocessor)}`
        raise GenerationError, "Could not preprocess using #{preprocessor}"      
      end
    end
    
    # Run LaTeX output generation step on the source file
    def process!
      unless `#{command(processor)}`
        raise GenerationError, "Could not generate PDF using #{processor}"      
      end
    end
    
    # Check the output file has been generated correctly
    def verify!
      unless File.exists?(result_file)
        raise GenerationError, "Could not find result PDF #{result_file} after generation.\nCheck #{log_file}"
      end
    end
    
    # Load the output file and return its contents
    def result_as_string
      File.open(result_file, 'rb') { |f| f.read }
    end
    
    # Should we pre-process?
    def preprocessing?
      preprocess_count > 0
    end
    
    def preprocess_count
      case @options[:preprocess]
        when Numeric
          @options[:preprocess].to_i
        when true
          1
        else
          0
      end
    end
    
    # Produce a list of environment variables to prefix the process and 
    # preprocess commands.
    #
    def environment_vars
      list = [tex_inputs, command_prefix].compact
      list.empty? ? "" : list.join(" ") + " "
    end
    
    # Compile list of extra directories to search for LaTeX packages, using
    # the file or array of files held in the :tex_inputs option.
    #
    def tex_inputs
      if inputs = @options[:tex_inputs]
        inputs = [inputs].flatten.select { |i| File.exists? i }
        "TEXINPUTS='#{inputs.join(':')}:'"
      else
        nil
      end
    end
    
    # Occasionally it is useful to be able to prefix the LaTeX commands with 
    # extra environment variables, for example the +rlatex+ program,
    #
    #   LATEXPRG=pdflatex rlatex [FILE...]
    #
    # which runs the command +pdflatex+ repeatedly until LaTeX is satisfied all
    # cross-references etc. are stable.
    #
    # To achieve this with RTeX, use 
    #
    #   :processor => "rlatex", :command_prefix => "LATEXPRG=pdflatex"
    #
    def command_prefix
      if prefix = @options[:command_prefix]
        prefix = [prefix].flatten.join(" ")
      else
        nil
      end
    end
    
    def source_file
      @source_file ||= file(:tex)
    end
    
    def log_file
      @log_file ||= file(:log)
    end
    
    def result_file
      @result_file ||= file(@options[:tex] ? :tex : :pdf)
    end
    
    def tempdir
      @options[:tempdir]
    end
    
    def file(extension)
      File.join(tempdir.to_s, "document.#{extension}")
    end
    
    def generating?
      !@options[:tex]
    end
    
  end
end
