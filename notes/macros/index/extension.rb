require 'asciidoctor/extensions'

include ::Asciidoctor

class IndexMacro < Extensions::BlockMacroProcessor
  use_dsl

  named :index

  def process parent, target, attrs
    
    level = @get_level(attrs.depth)

    html = <<~END
    ## Hi
    END

    create_block parent, :markup, html, attrs, subs: nil
    # create_pass_block parent, html, attrs, subs: nil
  end

  def get_level depth {
    out = []
    files = Dir[ parent/*.(adoc|html)' ].select{|f| File.file? f }
    dirs = Dir[ parent/*' ].select{|d| File.directory? d }

    files.each do |f|
      out.push f.name
    end

    if depth > 0
      dirs.each do |d|
        out.push { :name: d.name, :children: @get_level depth - 1}
      end
    end
  }
end