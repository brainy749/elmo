class MissionAssignment < ActiveRecord::Base
  belongs_to(:mission)
  belongs_to(:role)
  belongs_to(:user)
end
