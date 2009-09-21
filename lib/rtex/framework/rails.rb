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
      end
      
      module ControllerMethods
        
        def rtex(output, options, *args, &block)
          Thread.current[:_rendering_rtex] = true
          send_options = { 
            :disposition => (options.delete(:disposition) || 'inline'),
            :url_based_filename => true,
            :filename => (options.delete(:filename) || nil) }
        
          RTeX::Tempdir.open do |dir|
            # Make directory accessible to view
            @rtex_dir = dir
            # Render view into LaTeX string
            latex = render(options, *args, &block)
            
            case output
              when :latex
                send_data latex, send_options.merge(:type => 'text/x-tex', :length => latex.length)
              when :pdf
                pdf = RTeX::Document.new(latex, options.merge(:processed => true, :tempdir => dir)).to_pdf
                send_data pdf, send_options.merge(:type => 'application/pdf', :length => pdf.length)
            end
            
          end
          
        end
      end
      
      module HelperMethods
        # Similar to h()
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
      end
      
    end
  end
end
