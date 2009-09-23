require 'tempfile'

module RTeX
  module Framework #:nodoc:   
    module Rails #:nodoc:
      
      def self.setup
        RTeX::Document.options[:tempdir] = File.expand_path(File.join(RAILS_ROOT, 'tmp'))
        if ActionView::Base.respond_to?(:register_template_handler)
          ActionView::Base.register_template_handler(:rtex, TemplateHandler)
        else
          ActionView::Template.register_template_handler(:rtex, TemplateHandler)
        end
        ActionController::Base.send(:include, ControllerMethods)
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
      
      
      module ControllerMethods
        
        def self.included(base) #:nodoc:
          base.alias_method_chain :render, :rtex
        end
        
        # Extends the base +ActionController#render+ method by checking whether
        # the template is RTeX-capable and creating an RTeX::Document in that 
        # case.
        #
        # If you have view templates saved, for example, as "show.html.erb" and 
        # "show.pdf.rtex" in an ItemsController, one could write the controller
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
        # To see the underlying LaTeX code that generated the PDF, create 
        # another view called "show.tex.rtex" which includes the single line
        #
        #   <%= include_template_from "items/show.pdf.rtex" -%>
        #
        # and include the following in the controller action
        # 
        #   format.tex { render :filename => "item_information_source.tex" }
        #
        # This may be helpful during debugging or for saving pre-compiled parts
        # of LaTeX documents for later processing into PDFs.
        #
        def render_with_rtex(options=nil, extra_options={}, &block)
          if conditions_for_rtex(options)
            render_rtex(default_template, options, extra_options, &block)
          else
            render_without_rtex(options, extra_options, &block)
          end
        end
        
      private
        
        def render_rtex(template, options={}, extra_options={}, &block)
          RTeX::Tempdir.open do |dir|
            # Make LaTeX temporary directory accessible to view
            @rtex_dir = dir
            
            # Render view into LaTeX document string
            latex = render_without_rtex(options, extra_options, &block)
            
            # HTTP response options
            send_options = { 
              :disposition => (options.delete(:disposition) || 'inline'),
              :url_based_filename => true,
              :filename => (options.delete(:filename) || nil),
              :type => template.mime_type.to_s }
            
            # Document options
            rtex_options = options.merge(:tempdir => dir).reverse_merge(
              :processed => true,
              :tex_inputs => File.join(RAILS_ROOT,'lib','latex') )
            
            # Content type requested
            content_type = template.content_type.to_sym
            
            # Send appropriate data to client
            case content_type
              when :tex
                send_data latex, send_options.merge(:length => latex.length)
              when :pdf
                pdf = RTeX::Document.new(latex, rtex_options).to_pdf
                send_data pdf, send_options.merge(:length => pdf.length)
              else
                raise "RTeX: unknown content type requested: #{content_type}"
            end
          end
        end
        
        def conditions_for_rtex(options)
          begin
            # Do not override the +:text+ rendering, because send_data uses this
            !options[:text] && 
            # Check whether the default template is one managed by the 
            # RTeX::Framework::Rails::TemplateHandler
            :rtex == default_template.extension.to_sym 
          rescue
            false
          end
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
        
        # Copy the contents of another template into the current one, like 
        # rendering a partial but without have to add an underscore to the 
        # filename.
        #
        def include_template_from(from)
          other_file = @template.view_paths.find_template(from).relative_path
          render(:inline => File.read(other_file))
        end
        
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
