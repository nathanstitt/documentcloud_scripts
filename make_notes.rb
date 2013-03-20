#!/usr/bin/env ruby

require_relative 'mechanize_document_cloud'
require 'faker'
MechanizeDocumentCloud.site = 'https://staging.documentcloud.org/'

#MechanizeDocumentCloud.basic_auth = YAML::load(File.read('staging.yml'))

dc=MechanizeDocumentCloud.new( ARGV[0], ARGV[1] )

docid=625058

$RNG = Random.new(1234)

pages = dc.get("/documents/#{docid}.json").pages


dc.get("/documents/#{docid}/annotations" ).each do | note |
  dc.delete("/documents/#{docid}/annotations/#{note.id}")
end

def rand_location
  (0..3).map{|n| ($RNG.rand * 850).to_i}.join(',')
end

(1..pages).each do | pg |
  defaults = { :page_number=>pg, :access=>'public' }
  if 0 == pg % 2
    dc.post("/documents/#{docid}/annotations", defaults.merge({
              :location=> rand_location, :content=>Faker::Lorem.sentences.join(' '),
              :title=>"#{pg}-#{Faker::Company.catch_phrase}"
            }) )
    puts pg
  end
  dc.post("/documents/#{docid}/annotations", defaults.merge({
            :content=>Faker::Lorem.sentences.join(' '),
            :title=>"#{pg}-#{Faker::Company.catch_phrase}"
          }) )
end

new_order = (1..pages).to_a.shuffle
p new_order
File.open('page_order.yml', 'w') {|f| f.write(YAML.dump(new_order)) }


dc.post("/documents/#{docid}/reorder_pages",{
          :page_order=>new_order
        })


# #sleep 3

# new_order.map

# reset_order = [];

# new_order.each_with_index{|old,indx| reset_order[old]=indx+1 }
# reset_order.shift
# p reset_order

# dc.post("/documents/#{docid}/reorder_pages",{
#           :page_order=>reset_order
#         })
