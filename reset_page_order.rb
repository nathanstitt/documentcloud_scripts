#!/usr/bin/env ruby

require_relative 'mechanize_document_cloud'

MechanizeDocumentCloud.site = 'https://staging.documentcloud.org/'
MechanizeDocumentCloud.basic_auth = YAML::load(File.read('staging.yml'))

dc=MechanizeDocumentCloud.new( ARGV[0], ARGV[1] )

docid=502557

order=YAML.load(File.read('page_order.yml'))
reset_order = []
order.each_with_index{|old,indx| reset_order[old]=indx+1 }

reset_order.shift

dc.post("/documents/#{docid}/reorder_pages",{
          :page_order=>reset_order
        })

p reset_order
