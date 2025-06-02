require 'cgi'

unless URI.respond_to?(:escape)
  module URI
    def self.escape(str)
      CGI.escape(str.to_s)
    end
  end
end