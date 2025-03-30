Quickbooks.minorversion = '75'

module Quickbooks
  module Model
    class ReportJSON
      attr_accessor :json

      def initialize(attributes={})
        attributes.each {|key, value| public_send("#{key}=", value) }
      end

      def find_row(label)
        all_rows.find {|r| r[0] == label }
      end

      def all_rows
        data = []
        json_data = JSON.parse(json)["Rows"]

        # Process each main section (Income, COGS, Expenses, etc.)
        json_data["Row"].each do |section|
          # Add section header if present
          if section["Header"] && section["Header"]["ColData"]
            data << section["Header"]["ColData"].map { |c| process_value(c["value"]) }
          end

          # Process rows within the section
          if section["Rows"] && section["Rows"]["Row"]
            process_rows(section["Rows"]["Row"], data)
          end

          # Add section summary if present
          if section["Summary"] && section["Summary"]["ColData"]
            data << section["Summary"]["ColData"].map { |c| process_value(c["value"]) }
          end
        end

        { "rows" => data }
      end

      private

      def process_rows(rows, data)
        rows.each do |row|
          if row["type"] == "Data" && row["ColData"]
            # Simple data row
            data << row["ColData"].map { |c| process_value(c["value"]) }
          elsif row["type"] == "Section"
            # Nested section
            if row["Header"] && row["Header"]["ColData"]
              data << row["Header"]["ColData"].map { |c| process_value(c["value"]) }
            end

            if row["Rows"] && row["Rows"]["Row"]
              process_rows(row["Rows"]["Row"], data)
            end

            if row["Summary"] && row["Summary"]["ColData"]
              data << row["Summary"]["ColData"].map { |c| process_value(c["value"]) }
            end
          end
        end
      end

      def process_value(value)
        return nil unless value.present?
        return value if !(Float(value) rescue false)
        float_value = value.to_f
        if float_value == float_value.to_i
          sprintf("%.1f", float_value)
        elsif (float_value * 10).to_i == float_value * 10
          sprintf("%.1f", float_value)
        else
          sprintf("%.2f", float_value)
        end
      end
    end
  end

  module Service
    class ReportsJSON < BaseServiceJSON

      def url_for_query(which_report = 'BalanceSheet', date_macro = 'This Fiscal Year-to-date', options = {})
        xml_service = Quickbooks::Service::Reports.new
        xml_service.company_id = self.company_id
        xml_service.oauth = self.oauth
        xml_service.url_for_query(which_report, date_macro, options)
      end

      def query(object_query = 'BalanceSheet', date_macro = 'This Fiscal Year-to-date', options = {})
        do_http_get(url_for_query(object_query, date_macro, options))
        Quickbooks::Model::ReportJSON.new(:json => @last_response_json)
      end
    end
  end
end