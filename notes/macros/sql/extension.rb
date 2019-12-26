require 'asciidoctor/extensions'
require 'csv'
require 'mysql2'
require 'pg'

include ::Asciidoctor

class SQLMacro < Extensions::BlockMacroProcessor
  use_dsl

  named :sql

  @@connections = {
    Prod_RDS: {
      port: 5440,
      username: ENV['PROD_RDS_USER'],
      password: ENV["PROD_RDS_PASS"],
      db: 'statsdb',
      type: :pg
    },
    Prod_DW: {
      port: 5439,
      username: ENV['PROD_DW_USER'],
      password: ENV["PROD_DW_PASS"],
      db: 'statsdb',
      type: :pg
    },
    Prod_Jobs: {
      port: 33308,
      username: ENV["PROD_JOBS_USER"],
      password: ENV["PROD_JOBS_PASS"],
      db: 'datacollector',
      type: :mysql
    }
  }

  def process parent, target, attrs
  
    conn = @@connections[target.to_sym]
    query = attrs["query"]

    if conn[:type] == :mysql
      client = Mysql2::Client.new(host: "127.0.0.1", username: conn[:username], port: conn[:port], password: conn[:password], database: conn[:db])
      results = client.query(query)
    else
      client = PG.connect(host: "127.0.0.1", user: conn[:username], port: conn[:port], password: conn[:password], dbname: conn[:db] )
      results = client.exec(query)
    end


    headers = ""
    results.fields.each do |field|
      headers += <<~END
      <th class="tableblock halign-left valign-top">
        #{field}
      </th>
      END
    end

    rows = ""
    results.each do |row| 
      cols = ""
      row.values.each do |col|
        cols += <<~END
        <td class="tableblock halign-left valign-top">
          #{col}
        </td>
        END
      end
      rows += <<~END
        <tr>
          #{cols}
        </tr>
      END
    end

    caption = query
    if attrs["title"] 
      caption = attrs["title"]
    end

    csv_string = CSV.generate do |csv|
      csv << results.fields

      results.each do |row| 
        csv << row.values
      end
    end


    html = <<~END
      <table class="tableblock frame-all grid-all stretch" style="width: 100%;">
        <div style="display: none;">#{csv_string}</div>
        <caption title="#{query}" class="title">#{caption}</caption>
        <button style="position: absolute; top: 0px; right: 0px;" onclick="console.dir(event); downloadData('#{caption}'.$slugify()+'.csv', event.target.parentNode.children[0].innerText)">CSV</button>
        <tbody> 
          <tr>
            #{headers}
          </tr>
          #{rows}
        </tbody>
      </table>
    END

    create_pass_block parent, html, attrs, subs: nil
  end
end