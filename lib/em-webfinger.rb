require File.join(Rails.root, 'lib/hcard')
require File.join(Rails.root, 'lib/webfinger_profile')

class EMWebfinger
  TIMEOUT = 5
  REDIRECTS = 3
  OPTS = {:timeout => TIMEOUT, :redirects => REDIRECTS}
  def initialize(account)
    @account = account.strip.gsub('acct:','').to_s
    @callbacks = []
    @ssl = true 
    Rails.logger.info("event=EMWebfinger status=initialized target=#{account}")
    # Raise an error if identifier has a port number 
    #raise "Identifier is invalid" if(@account.strip.match(/\:\d+$/))
    # Raise an error if identifier is not a valid email (generous regexp)
    #raise "Identifier is invalid" if !(@account=~ /^[a-zA-Z][\w\.-]*[a-zA-Z0-9]@[a-zA-Z0-9][\w\.-]*[a-zA-Z0-9]\.[a-zA-Z][a-zA-Z\.]*[a-zA-Z]$/)
  end 
  def fetch
    if @callbacks.empty?
      Rails.logger.info("event=EMWebfinger status=abort target=#{@account} callbacks=empty")
      raise 'you need to set a callback before calling fetch' 
    end
    person = Person.by_account_identifier(@account)
    if person
      Rails.logger.info("event=EMWebfinger status=local target=#{@account}")
      process_callbacks person
    else
      Rails.logger.info("event=EMWebfinger status=remote target=#{@account}")
      get_xrd
    end
  end

  def on_person(&block)
    @callbacks << block
    self.fetch
  end

  private

  def get_xrd
    http = EventMachine::HttpRequest.new(xrd_url).get OPTS
    http.callback { 
      profile_url = webfinger_profile_url(http.response)
      if profile_url 
        get_webfinger_profile(profile_url) 
      elsif @ssl
        @ssl = false
        get_xrd
      else
        process_callbacks  I18n.t('webfinger.not_enabled', :account => @account)
      end
    }

    http.errback {
      if @ssl
        @ssl = false
        get_xrd
      else
        process_callbacks I18n.t('webfinger.xrd_fetch_failed', :account => @account)
      end }
  end


  def get_webfinger_profile(profile_url)
     http = EventMachine::HttpRequest.new(profile_url).get OPTS
     http.callback{ make_person_from_webfinger(http.response) }
     http.errback{ process_callbacks I18n.t('webfinger.fetch_failed', :profile_url => profile_url) }
  end

  def make_person_from_webfinger(webfinger_profile)
    unless webfinger_profile.strip == ""
      
      begin
        wf_profile = WebfingerProfile.new(@account, webfinger_profile)
      rescue
        return process_callbacks "No person could be constructed from this webfinger profile."
      end
      
      http = EventMachine::HttpRequest.new(wf_profile.hcard).get OPTS
      http.callback{
        begin
          hcard = HCard.build http.response
          p = Person.build_from_webfinger(wf_profile, hcard)
          process_callbacks(p)
        rescue
          process_callbacks I18n.t 'webfinger.no_person_constructed'
        end
      }
      http.errback{process_callbacks I18n.t('webfinger.hcard_fetch_failed', :account => @account) }
    end
  end


  def process_callbacks(person)
    Rails.logger.info("event=EMWebfinger status=callbacks_started target=#{@account} response='#{person.is_a?(String) ? person : person.id}'")
    @callbacks.each { |c|
      begin
        c.call(person)
      rescue Exception => e
        Rails.logger.info("event=EMWebfinger status=error_on_callback error='#{e.inspect}'")
      end
    }
    Rails.logger.info("event=EMWebfinger status=complete target=#{@account}")
  end


  ##helpers
  private

  def webfinger_profile_url(xrd_response)
    doc = Nokogiri::XML::Document.parse(xrd_response)  
    return nil if doc.namespaces["xmlns"] != "http://docs.oasis-open.org/ns/xri/xrd-1.0" 
    swizzle doc.at('Link[rel=lrdd]').attribute('template').value
  end

  def xrd_url
    domain = @account.split('@')[1]
    "http#{'s' if @ssl}://#{domain}/.well-known/host-meta"
  end
  
  def swizzle(template)
    template.gsub '{uri}', @account
  end
end
