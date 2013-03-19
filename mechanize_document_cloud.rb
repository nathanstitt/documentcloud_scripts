#!/Usr/bin/env ruby

require 'active_support/core_ext/class/attribute_accessors'
require 'active_support/core_ext/object/to_query'
require 'active_support/json'
require 'hashie'
require 'mechanize'

class MechanizeDocumentCloud

  # might as well use since we're pulling
  # in active_support
  cattr_accessor :site do
    'https://dev.dcloud.org'
  end

  def initialize( login, password )
    page = http.get( self.site + '/login' )
    page.forms.first.email = login
    page.forms.first.password = password
    welcome = page.forms.first.submit
    @csrf=welcome.search("meta[name=csrf-token]").attr('content')
  end

  def http
    @agent ||= Mechanize.new
    @agent.agent.http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @agent
  end

  def get( url, params={} )
    decoded_response http.get( url + '?' + params.to_query )
  end

  def post( url, params={} )
    decoded_response http.post( url, params.to_json, headers  )
  end

  def delete( url, params={} )
    decoded_response http.delete( url+'?'+params.to_query )
  end

  private

  def decoded_response( resp )
    data = ActiveSupport::JSON.decode( resp.body )
    if data.is_a?(Array)
      data.map{|el| el.is_a?(Hash) ? Hashie::Mash.new(el) : el }
    elsif data.is_a?(Hash)
      Hashie::Mash.new(data)
    else
      data
    end
  end

  def headers
    {
      'X-Requested-With' => 'XMLHttpRequest',
      'Content-Type' => 'application/json; charset=utf-8',
      'Accept' => 'application/json, text/javascript, */*',
      'X-CSRF-Token' => @csrf
    }
  end
end
