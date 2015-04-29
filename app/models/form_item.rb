class FormItem < ActiveRecord::Base
  include MissionBased, FormVersionable, Replication::Replicable

  acts_as_list column: :rank, scope: [:ancestry]

  belongs_to(:form)

  # These associations are really only applicable to Questioning, but
  # they are defined here to allow eager loading.
  belongs_to(:question, autosave: true, inverse_of: :questionings)
  has_many(:answers, foreign_key: :questioning_id, dependent: :destroy, inverse_of: :questioning)
  has_one(:condition, foreign_key: :questioning_id, autosave: true, dependent: :destroy, inverse_of: :questioning)
  has_many(:referring_conditions, class_name: 'Condition', foreign_key: :ref_qing_id, dependent: :destroy, inverse_of: :ref_qing)
  has_many(:standard_form_reports, class_name: 'Report::StandardFormReport', foreign_key: :disagg_qing_id, dependent: :nullify)

  before_create(:set_mission)

  has_ancestry cache_depth: true

  validate :parent_must_be_group

  # Checks for gaps in ranks in the db directly.
  def self.rank_gaps?
    !find_by_sql("SELECT id FROM form_items fi1 WHERE fi1.rank > 1 AND NOT EXISTS (
      SELECT id FROM form_items fi2 WHERE fi2.ancestry = fi1.ancestry AND fi2.rank = fi1.rank - 1)").empty?
  end

  def self.duplicate_ranks?
    !find_by_sql("SELECT ancestry, rank FROM form_items WHERE ancestry is NOT NULL
      AND ancestry != '' GROUP BY ancestry, rank HAVING COUNT(id) > 1;").empty?
  end

  # Gets all leaves of the subtree headed by this FormItem, sorted.
  # These should all be Questionings.
  def sorted_leaves
    _sorted_leaves(arrange_and_sort().values[0])
  end

  def arrange_and_sort
    # This is the only way (apparently) to do eager loading with arrange.
    self.class.arrange_nodes(subtree.order('(case when ancestry is null then 0 else 1 end), ancestry, rank').to_a)
  end

  # Moves item to new rank and parent.
  def move(new_parent_id, new_rank)
    transaction do
      update_attributes(parent: FormItem.find(new_parent_id), rank: new_rank)

      # Extra safeguards to make sure ranks are correct. acts_as_list should prevent these.
      if self.class.rank_gaps?
        errors.add(:base, 'That update would have caused gaps in ranks.')
        raise ActiveRecord::Rollback
      elsif self.class.duplicate_ranks?
        errors.add(:base, 'That update would have caused duplicate ranks.')
        raise ActiveRecord::Rollback
      end
    end
  end

  private
    # copy mission from question
    def set_mission
      self.mission = form.try(:mission)
    end

    def _sorted_leaves(nodes)
      nodes.map do |form_item, children|
        if form_item.is_a?(Questioning)
          form_item
        else
          _sorted_leaves(children).flatten
        end
      end
    end

    def parent_must_be_group
      errors.add(:parent, :must_be_group) unless parent.nil? || parent.is_a?(QingGroup)
    end

end