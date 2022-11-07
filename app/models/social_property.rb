class SocialProperty < ApplicationRecord
  belongs_to :studio
  validates :profile_url, format: URI::regexp(%w[http https])

  def self.aggregate!(social_properties)
    return {} unless social_properties.any?

    all_dates =
      social_properties.reduce([]) do |acc, sp|
        [*acc, *sp.snapshot.keys].uniq
      end.map{|d| Date.parse(d)}

    (all_dates.min..all_dates.max).reduce({}) do |acc, date|
      acc[date] = social_properties.reduce(0) do |agg, sp|
        # Find the closest earlier sample to this date
        closest_earlier_sample =
          sp.snapshot.keys.map{|d| Date.parse(d)}.sort.reduce(nil) do |closest, sample_date|
            next closest if sample_date > date
            next sample_date if closest.nil?
            closest < sample_date ? sample_date : closest
          end
        agg += sp.snapshot[closest_earlier_sample.try(:iso8601)] || 0
      end
      acc
    end
  end

  def generate_snapshot!
    if profile_url.include?("instagram.com")
      puts "~> Requesting (via cryingparty) to #{profile_url}"
      uri = URI.parse("https://cryingparty.vercel.app/api/instagram/#{profile_url.split("/").last}")
      res = Net::HTTP.get(uri)
      data = JSON.parse(res)
      if data["follower_count"] > 0
        update!(snapshot: snapshot.merge({ Date.today.iso8601 => data["follower_count"] }))
      end
      return
    end

    browser = Ferrum::Browser.new({
      timeout: 60,
      extensions: ['vendor/stealth.min.js'],
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
