require 'bundler'
require 'open3'

Bundler.require

require 'sinatra/base'


class MyApp < Sinatra::Base

    get "/file.pdf" do
        attachment Faker::Lorem.sentence.gsub(/\s+/,'_')+'.pdf'
        content_type 'application/pdf'

        Open3.popen3( File.dirname(__FILE__) + "/text2pdf") do |stdin, stdout, stderr|
            stdin.write document
            stdin.close_write
            return  stdout.read
        end
    end

    get "/file.txt" do
        attachment ( Faker::Lorem.sentence.gsub(/\s+/,'_')+'.txt' )
        document
    end

    private
    def document
        attachment ( Faker::Lorem.sentence.gsub(/\s+/,'_')+'.txt' )
        Faker::Name.name + "\n\n" +
            Faker::Lorem.paragraphs( 8 ).join("\n\n") + "\n"
    end
end

run MyApp
