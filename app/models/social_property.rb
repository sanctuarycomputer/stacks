class SocialProperty < ApplicationRecord
  belongs_to :studio
  validates :profile_url, format: URI::regexp(%w[http https])

  def generate_snapshot!
    browser = Ferrum::Browser.new({
      timeout: 60,
      extensions: ['vendor/stealth.min.js'],
      #browser_options: {
      #  'proxy-server': 'socks5://127.0.0.1:9050'
      #}
    })
    browser.headers.add({
      "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36",
      "Referer" => "https://www.google.com/",
    })

    puts "~> Navigating to #{profile_url}"
    browser.go_to(profile_url)
    # browser.network.wait_for_idle
    sleep 10.seconds

    followers_el =
      if profile_url.include?("twitter.com")
        browser.evaluate("Array.from(document.querySelectorAll('a')).find(a => a.href.endsWith('/followers'));")
      elsif profile_url.include?("instagram.com")
        browser.evaluate("Array.from(document.querySelectorAll('button')).find(b => b.innerText.includes('followers'));")
      elsif profile_url.include?("linkedin.com")
        browser.evaluate("Array.from(document.querySelectorAll('h3')).find(b => b.innerText.includes('followers'));")
      elsif profile_url.include?("facebook.com")
        browser.evaluate("Array.from(document.querySelectorAll('a')).find(b => b.innerText.includes('followers'));")
      end

    unless followers_el.present?
      browser.screenshot(path: "screenshot.png")
      url = "https://file.io?expires=3d"
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      form_data = [['file', File.open("screenshot.png", "rb")]]
      request.set_form form_data, 'multipart/form-data'
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end
      result = JSON.parse(response.body)
      puts "~> No element found for: #{profile_url}. Screenshot here: #{result["link"]}"
      return
    end

    followers_count = followers_el.inner_text.gsub(/[,.]/,'').split(" ").find{|t| (t.try(:to_i) || 0) > 0}.try(:to_i) || 0
    update!(snapshot: snapshot.merge({ Date.today.iso8601 => followers_count })) if followers_count > 0
  end
end
