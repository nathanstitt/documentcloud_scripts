#!/usr/bin/env ruby

require_relative 'mechanize_document_cloud'
require 'faker'

dc=MechanizeDocumentCloud.new( ARGV[0], ARGV[1] )

docid=417924 # 35

$RNG = Random.new(1234)

pages = dc.get("/documents/#{docid}.json").pages


dc.get("/documents/#{docid}/annotations" ).each do | note |
  dc.delete("/documents/#{docid}/annotations/#{note.id}")
end

def rand_location
  (0..3).map{|n| ($RNG.rand * 850).to_i}.join(',')
end

(1..pages).each do | pg |
  if 0 == pg % 2
    dc.post("/documents/#{docid}/annotations", {
              :page_number=>pg,
              :access=>'public',
              :location=> rand_location,
              :content=>Faker::Lorem.sentences.join(' '),
              :title=>"#{pg}-#{Faker::Company.catch_phrase}"
            })
    puts pg
  end
  dc.post("/documents/#{docid}/annotations", {
            :page_number=>pg,
            :access=>'public',
            :content=>Faker::Lorem.sentences.join(' '),
            :title=>"#{pg}-#{Faker::Company.catch_phrase}"
          })
end

new_order = (1..pages).to_a.shuffle.map(&:to_s)
p new_order
File.open('page_order.yml', 'w') {|f| f.write(YAML.dump(new_order)) }


dc.post("/documents/#{docid}/reorder_pages",{
          :page_order=>new_Order
        })
