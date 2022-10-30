class SocialProperty < ApplicationRecord
  belongs_to :studio
  validates :profile_url, format: URI::regexp(%w[http https])

  def generate_snapshot!
    browser = Ferrum::Browser.new(timeout: 60)
    browser.headers.add({
      "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36",
      "Referer" => "https://www.google.com/",
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

    return unless followers_el.present?
    followers_count = followers_el.inner_text.gsub(/[,.]/,'').split(" ").find{|t| (t.try(:to_i) || 0) > 0}.try(:to_i) || 0
    update!(snapshot: snapshot.merge({ DateTime.now.iso8601 => followers_count })) if followers_count > 0
  end
end
