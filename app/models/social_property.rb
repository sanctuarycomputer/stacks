class SocialProperty < ApplicationRecord
  belongs_to :studio
  validates :profile_url, format: URI::regexp(%w[http https])

  def generate_snapshot!
    browser = Ferrum::Browser.new(timeout: 60)
    browser.headers.add({
      "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36",
      "Referer" => "https://www.google.com/",
      "Cookie" => 'lang=v=2&lang=en-us; lidc="b=VGST06:s=V:r=V:a=V:p=V:g=2510:u=1:x=1:i=1667167195:t=1667253595:v=2:sig=AQE_kkroPVypqU1QrwkkfF6no9wxUBMH"; bcookie="v=2&7d795330-a473-497f-87a1-0db34e753f4f"; bscookie="v=1&20221030215954e8ff523c-f14e-41e7-8d82-24335bb00013AQGUYx9lilc1LdnHCTRUSGX_hdGLRR35'
    })
    browser.go_to(profile_url)

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

    binding.pry unless followers_el.present?
    followers_count = followers_el.inner_text.gsub(/[,.]/,'').split(" ").find{|t| t.to_i > 0}.try(:to_i) || 0
    update!(snapshot: snapshot.merge({ DateTime.now.iso8601 => followers_count })) if followers_count > 0
  end
end
