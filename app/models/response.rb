require 'xml'
require 'place_lookupable'

# ELMO - Secure, robust, and versatile data collection.
# Copyright 2011 The Carter Center
#
# ELMO is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# ELMO is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with ELMO.  If not, see <http://www.gnu.org/licenses/>.
# 
class Response < ActiveRecord::Base
  include PlaceLookupable
  
  belongs_to(:form)
  belongs_to(:place)
  has_many(:answers, :include => :questioning, :order => "questionings.rank", 
    :autosave => true, :validate => false, :dependent => :destroy)
  belongs_to(:user)
  
  attr_accessor(:modifier)
  
  # we turn off validate above and do it here so we can control the message and have only one message
  # regardless of how many answer errors there are
  validates(:user, :presence => true)
  validates(:observed_at, :presence => true)
  validate(:no_missing_answers)

  # only need to validate answers in web mode
  validates_associated(:answers, :message => "are invalid (see below)", :if => Proc.new{|r| r.modifier == "web"})
  
  before_save(:set_place)
  
  default_scope(includes({:form => :type}, :user, :place).order("responses.created_at DESC"))
  scope(:unreviewed, where(:reviewed => false))
  scope(:by, lambda{|user| where(:user_id => user.id)})
  
  self.per_page = 20
  
  def self.find_eager(id)
    includes([:form, {:answers => 
      {
        :choices => {:option => :translations}, 
        :option => :translations, 
        :questioning => {:question => [:type, :translations, {:option_set => {:options => :translations}}]}
      }
    }]).find(id)
  end
  
  def self.for_export(rel)
    find_by_sql(export_sql(rel))
  end
  
  # gets the list of fields to be searched for this class
  # includes whether they should be included in a default, unqualified search
  # and whether they are searchable by a regular expression
  def self.search_qualifiers
    [
      Search::Qualifier.new(:label => "formname", :col => "forms.name", :assoc => :forms),
      Search::Qualifier.new(:label => "formtype", :col => "form_types.name", :assoc => :form_types),
      Search::Qualifier.new(:label => "reviewed", :col => "responses.reviewed", :subst => {"yes" => "1", "no" => "0"}),
      Search::Qualifier.new(:label => "place", :col => "places.full_name", :assoc => :places, :partials => true),
      Search::Qualifier.new(:label => "submitter", :col => "users.name", :assoc => :users, :partials => true),
      Search::Qualifier.new(:label => "answer", :col => "answers.value", :assoc => :answers, :partials => true, :default => true),
      Search::Qualifier.new(:label => "source", :col => "responses.source")
    ]
  end
  
  def self.search_examples
    ['submitter:"john smith"', 'formname:polling', 'place:beirut', 'reviewed:yes']
  end

  def self.create_from_xml(xml, user)
    # parse xml
    doc = XML::Parser.string(xml).parse

    # get form id
    form_id = doc.root["id"] or raise ArgumentError.new("No form id.")
    form_id = form_id.to_i
    
    # create response object
    resp = new(:form_id => form_id, :user_id => user ? user.id : nil, :source => "odk", :modifier => "odk")
    qings = resp.form ? resp.form.visible_questionings : (raise ArgumentError.new("Invalid form id."))
    
    # loop over each child tag and create hash of question_code => value
    values = {}; doc.root.children.each{|c| values[c.name] = c.first? ? c.first.content : nil}
    
    # set the observe time if it's available
    if time = values.delete('startstamp')
      resp.observed_at = Time.zone.parse(time)
    end
    
    # loop over all the questions in the form and create answers
    place_bits = {}
    start_time = nil
    qings.each do |qing|
      # get value from hash
      str = values[qing.question.odk_code]
      # add answer
      resp.answers << Answer.new_from_str(:str => str, :questioning => qing)
    end

    # save the works
    resp.save!
  end
  
  # returns a human-readable description of how many responses have arrived recently
  def self.recent_count(rel)
    %w(hour day week month).each do |p|
      if (x = rel.where("created_at > ?", 1.send(p).ago).count) > 0 
        return "#{x} in the Past #{p.capitalize}"
      end
    end
    "No recent reports"
  end
  
  def visible_questionings
    # get visible questionings from form
    form.visible_questionings
  end
  
  def all_answers
    # make sure there is an associated answer object for each questioning in the form
    visible_questionings.collect{|qing| answer_for(qing) || answers.new(:questioning_id => qing.id)}
  end
  
  def all_answers=(params)
    # do a match on current and newer ids with the ID as the comparator
    answers.match(params.values, Proc.new{|a| a[:questioning_id].to_i}) do |orig, subd|
      # if both exist, update the original
      if orig && subd
        orig.attributes = subd
      # if submitted is nil, destroy the original
      elsif subd.nil?
        answers.delete(orig)
      # if original is nil, add the new one to this response's array
      elsif orig.nil?
        answers << Answer.new(subd)
      end
    end
  end

  def answer_for(questioning)
    # get the matching answer(s)
    answer_hash[questioning]
  end
  
  def answer_hash(options = {})
    @answer_hash = nil if options[:rebuild]
    @answer_hash ||= Hash[*answers.collect{|a| [a.questioning, a]}.flatten]
  end
  
  def observed_at_str; observed_at ? observed_at.strftime("%F %l:%M%p %z").gsub("  ", " ") : nil; end
  def observed_at_str=(t)
    self.observed_at = begin Time.zone.parse(t) rescue nil end
  end
  
  def form_name; form ? form.name : nil; end
  def submitter; user ? user.name : nil; end
  
  def place_field_name; "place"; end
  
  private
    def no_missing_answers
      answer_hash(:rebuild => true)
      visible_questionings.each do |qing|
        errors.add(:base, "Not all questions have answers") and return false if answer_for(qing).nil?
      end
    end
    
    def set_place
      # grab place from place bits unless the place has been set using the lookup tool
      unless place_id_changed?
        bits = {:changed => false}
        # loop over answers and find gps coords and/or place name, noting if either has changed      
        answers.each do |a|
          if bits[:coords].nil? && a.questioning.question.is_location?
            # if the gps location was set, split the string into lat/lng
            bits[:coords] = a.value? ? a.value.split(" ")[0..1] : false
            # note if the value was changed
            bits[:changed] = true if a.value_changed?
          elsif bits[:place_name].nil? && a.questioning.question.is_address?
            # save the place name
            bits[:place_name] = (a.value ? a.value[0..254] : "") || false
            # note if the value was changed
            bits[:changed] = true if a.value_changed?
          end
        end
        
        # find and set the place if either of the bits changed
        self.place = Place.find_or_create_with_bits(bits) if bits[:changed]
        return true
      end
      
      # ensure the place is non-temporary
      place.update_attributes(:temporary => false) if self.place
    end
    
    def self.export_sql(rel)
      # add all the selects
      rel = rel.select("responses.id AS response_id")
      rel = rel.select("responses.observed_at AS observation_time")
      rel = rel.select("responses.reviewed AS is_reviewed")
      rel = rel.select("forms.name AS form_name")
      rel = rel.select("form_types.name AS form_type")
      rel = rel.select("questions.code AS question_code")
      rel = rel.select("question_trans.str AS question_name")
      rel = rel.select("question_types.name AS question_type")
      rel = rel.select("users.name AS submitter_name")
      rel = rel.select("places.full_name AS place_full_name")
      rel = rel.select("points.long_name AS point")
      rel = rel.select("addresses.long_name AS address")
      rel = rel.select("localities.long_name AS locality")
      rel = rel.select("states.long_name AS state")
      rel = rel.select("countries.long_name AS country")
      rel = rel.select("places.latitude AS latitude")
      rel = rel.select("places.longitude AS longitude")
      rel = rel.select("concat(places.latitude, ',', places.longitude) AS latitude_longitude")
      rel = rel.select("answers.id AS answer_id")
      rel = rel.select("answers.value AS answer_value")
      rel = rel.select("IFNULL(aotr.str, cotr.str) AS choice_name")
      rel = rel.select("IFNULL(ao.value, co.value) AS choice_value")
      rel = rel.select("option_sets.name AS option_set")

      # add all the joins
      rel = rel.joins(Report::Join.list_to_sql([:users, :forms, :form_types, 
        :answers, :questionings, :questions, :question_types, :question_trans, :option_sets, :options, :choices,
        :places, :points, :addresses, :localities, :states, :countries]))
        
      rel.to_sql
    end
end
