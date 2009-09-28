require 'tempfile'

module RTeX
  module Framework #:nodoc:
    module Rails #:nodoc:
      
      def self.available_options
        [:disposition, :filename, :template_format]
      end
      
      def self.setup
        RTeX::Document.options[:tempdir] = File.expand_path(File.join(RAILS_ROOT, 'tmp'))
        if ActionView::Base.respond_to?(:register_template_handler)
          ActionView::Base.register_template_handler(:rtex, TemplateHandler)
        else
          ActionView::Template.register_template_handler(:rtex, TemplateHandler)
        end
        ActionView::Base.send(:include, HelperMethods)
      end
      
      
      class TemplateHandler < ::ActionView::TemplateHandlers::ERB
        # Due to significant changes in ActionView over the lifespan of Rails,
        # tagging compiled templates to set a thread local variable flag seems
        # to be the least brittle approach.
        def compile(template)
          # Insert assignment, but not before the #coding: line, if present
          super.sub(/^(?!#)/m, "Thread.current[:_rendering_rtex] = true;\n")
        end
      end
      
      module HelperMethods
      
        # Make the supplied text safe for the LaTeX processor, in the same way 
        # that h() works for HTML documents.
        #
        def latex_escape(*args)
          # Since Rails' I18n implementation aliases l() to localize(), LaTeX
          # escaping should only be done if RTeX is doing the rendering.
          # Otherwise, control should be be passed to localize().
          if Thread.current[:_rendering_rtex]
            RTeX::Document.escape(*args)
          else
            localize(*args)
          end
        end
        alias :l :latex_escape
        
        # Obtain the temporary directory RTeX is currently using
        attr_reader :rtex_dir
        
        # Include an image file into the current LaTeX document.
        #
        # For example,
        #
        #   \includegraphics{<%= graphics_file("some file.png") -%>}
        #
        # will copy "public/images/some file.png" to a the current RTeX 
        # temporary directory (with a LaTeX-safe filename) and reference it in 
        # the document like this:
        #
        #   \includegraphics{/tmp/rtex/rtex-random-number/image-file.png}
        #
        def graphics_file(file, reference_original_file=false)
          source = Pathname.new file
          source = Pathname.new(ActionView::Helpers::ASSETS_DIR) + "images" + source unless source.absolute?
          
          if reference_original_file
            source.to_s
          else
            destination = Pathname.new(@rtex_dir) + latex_safe_filename(source.basename)
            FileUtils.copy source, destination
            destination.to_s
          end
        end
        
        # Save the supplied image data to the RTeX temporary directory and 
        # return the filename for inclusion in the current document.
        #
        #   \includegraphics{<%= graphics_data(object.to_png) -%>}
        #
        def graphics_data(data)
          destination = Pathname.new(@rtex_dir) + latex_safe_filename(filename)
          File.open(destination, "w") { |f| f.write data }
          dst.to_s
        end
        
      private
        
        def latex_safe_filename(input)
          # Replace non-ASCII characters
          input = ActiveSupport::Inflector.transliterate(input.to_s).to_s
          # Replace non-LaTeX-friendly characters with a dash
          input.gsub(/[^a-z0-9\-_\+\.]+/i, '-')
        end
        
      end
    end
  end
end


module ActionController
  class Base
  
    # Extends the base +ActionController#render+ method by checking whether
    # the template is RTeX-capable and creating an RTeX::Document in that 
    # case.
    #
    # If you have view templates saved, for example, as "show.html.erb" and 
    # "show.tex.rtex" in an ItemsController, one could write the controller
    # action like this:
    #
    #   def show
    #     # set up instance variables
    #     # ...
    #     respond_to do |format|
    #       format.html
    #       format.pdf { render :filename => "Item Information.pdf" }
    #     end
    #   end
    #
    # As well as the options available to a new RTeX::Document, the 
    # following may be supplied here:
    #
    # [+:disposition+] 'inline' (default) or 'attachment'
    # [+:filename+] +nil+ (default) results in the final part of the 
    #               request URL being used.
    #
    # To see the underlying LaTeX code that generated the PDF, include the
    # following in the controller action's +respond_to+ block:
    # 
    #   format.tex
    #
    # This may be helpful during debugging or for saving pre-compiled parts
    # of LaTeX documents for later processing into PDFs.
    #
    def render_with_rtex(options = nil, extra_options = {}, &block)
      @_render_options = (options || {}).slice\
        *(RTeX::Document.available_options + RTeX::Framework::Rails.available_options)
      
      # Remember which format the client has requested
      @_render_options[:output_format] = @template.template_format
      
      # Continue using the original +#render+ method
      render_without_rtex(options, extra_options, &block)
    end
    
    alias_method :render_without_rtex, :render #:nodoc:
    alias_method :render, :render_with_rtex #:nodoc:
    
    # Store additional options passed to +#render+ for later
    attr_accessor :_render_options #:nodoc:
  end
end


module ActionView
  class Base
    def render_with_rtex(options = {}, local_assigns = {}, &block)
      if is_rtex?(options)
        render_rtex(options, local_assigns, &block)
      else
        render_without_rtex(options, local_assigns, &block)
      end
    end
    alias_method :render_without_rtex, :render
    alias_method :render, :render_with_rtex
    
    def is_rtex?(options)
      options[:file] and options[:file].extension == "rtex"
    end
    
    def render_rtex(options={}, local_assigns={}, &block)
      RTeX::Tempdir.open do |dir|
        # Make LaTeX temporary directory accessible to view
        @rtex_dir = dir.to_s
        
        # File input and output formats
        output_format = controller._render_options.delete(:output_format)
        template_format = controller._render_options.delete(:template_format) || :tex
        @template_format = template_format
        
        # Render view into LaTeX document string
        latex = render_without_rtex(options, local_assigns, &block)
        
        # HTTP response options
        framework_opts = controller._render_options.slice(*RTeX::Framework::Rails.available_options)
        framework_opts.reverse_merge!\
          :disposition => 'inline',
          :url_based_filename => true,
          :filename => nil,
          :type => Mime::Type.lookup_by_extension(output_format.to_s).to_s
        
        # Document options
        document_opts = controller._render_options.slice(*RTeX::Document.available_options)
        document_opts.merge!(:tempdir => dir).reverse_merge!\
          :processed => true,
          :tex_inputs => File.join(RAILS_ROOT,'lib','latex')
        
        # Send appropriate data to client
        case output_format
          when :tex
            controller.send :send_data, latex, framework_opts.merge(:length => latex.length)
          when :pdf
            pdf = RTeX::Document.new(latex, document_opts).to_pdf
            controller.send :send_data, pdf, framework_opts.merge(:length => pdf.length)
          else
            raise "RTeX: unknown content type requested: #{output_format}"
        end
      end
    end
  end
  
  
  class PathSet < Array
    # When ActionView notices that we are requested a PDF file without there 
    # being a *.pdf.rtex template available, it will throw an error.
    #
    # To work around this, we attempt to see if a *.tex.rtex template exists
    # instead.
    #
    def find_template_with_rtex(original_template, format = nil, html_fallback = true)
      begin
        find_template_without_rtex(original_template, format, html_fallback)
      rescue MissingTemplate
        find_template_without_rtex(original_template, :tex, html_fallback)
      end
    end
    alias_method :find_template_without_rtex, :find_template
    alias_method :find_template, :find_template_with_rtex
  end
end
