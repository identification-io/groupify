require 'active_record'
require 'combustion'

ActiveRecord::Migration.verbose = false
ActiveRecord::Base.logger = Logger.new(STDOUT) if DEBUG

Combustion.initialize! :active_record
puts "ActiveRecord Version: #{ActiveSupport::VERSION::STRING}, Adapter: #{ActiveRecord::Base.connection.adapter_name}"

RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner[:active_record].strategy = :transaction
  end

  config.before(:each) do
    DatabaseCleaner[:active_record].start
  end

  config.after(:each) do
    DatabaseCleaner[:active_record].clean
  end
end

require 'groupify/adapter/active_record'

Groupify.configure do |config|
  config.configure_legacy_defaults!
end

require_relative './active_record/ambiguous'
require_relative './active_record/user'
require_relative './active_record/manager'
require_relative './active_record/widget'
require_relative './active_record/namespaced/member'
require_relative './active_record/project'
require_relative './active_record/group'
require_relative './active_record/organization'
require_relative './active_record/group_membership'
require_relative './active_record/classroom'
require_relative './active_record/parent'
require_relative './active_record/student'
require_relative './active_record/university'
require_relative './active_record/enrollment'

describe Group do
  it { should respond_to :members}
  it { should respond_to :add }
end

describe User do
  it { should respond_to :groups}
  it { should respond_to :in_group?}
  it { should respond_to :in_any_group?}
  it { should respond_to :in_all_groups?}
  it { should respond_to :shares_any_group?}
end

describe Groupify::ActiveRecord do
  let(:user) { User.create! }
  let(:group) { Group.create!(id: 10) }
  let(:classroom) { Classroom.create!(id: 10) }
  let(:organization) { Organization.create!(id: 11) }

  describe "polymorphic groups" do
    context "memberships" do
      it "auto-saves new group record when adding a member" do
        group = Group.new
        group.add user

        expect(group.persisted?).to eq true
        expect(user.persisted?).to eq true
        expect(group.users.size).to eq 1
        expect(user.groups.size).to eq 1
        expect(group.users).to include(user)
        expect(user.groups).to include(group)

        user.reload

        expect(user.groups.first).to eq group

        group.reload

        expect(group.users.first).to eq user
      end

      it "auto-saves new member record when adding to a group" do
        group = Group.create!
        user = User.new
        group.add user

        expect(group.persisted?).to eq true
        expect(user.persisted?).to eq true
        expect(group.users.size).to eq 1
        expect(user.groups.size).to eq 1
        expect(group.users).to include(user)
        expect(user.groups).to include(group)

        user.reload

        expect(user.groups.first).to eq group

        group.reload

        expect(group.users.first).to eq user
      end

      it "finds multiple records for different models with same ID" do
        group.add user
        classroom.add user
        organization.add user

        expect(group.id).to eq(10)
        expect(classroom.id).to eq(10)
        expect(organization.id).to eq(11)

        membership_groups = user.group_memberships_as_member.map(&:group)

        expect(membership_groups).to include(group, classroom, organization)
        expect(GroupMembership.for_groups([group, classroom]).count).to eq(2)
        expect(GroupMembership.for_groups([group, classroom]).map(&:group)).to include(group, classroom)
        expect(GroupMembership.for_groups([group, classroom]).distinct.count).to eq(2)
        expect(GroupMembership.for_groups([group, classroom, organization]).count).to eq(3)
        expect(GroupMembership.for_groups([group, classroom, organization]).map(&:group)).to include(group, classroom, organization)
        expect(GroupMembership.for_groups([group, classroom]).map(&:member).uniq.size).to eq(1)
        expect(GroupMembership.for_groups([group, classroom]).map(&:member).uniq.first).to eq(user)
      end

      it "infers class name for association based on association name" do
        organization  = Organization.create!
        organization1 = Organization.create!
        organization2 = Organization.create!
        group = Group.create!
        manager = Manager.create!

        organization.add organization1
        organization.add organization2
        organization.add group
        organization.add manager

        expect(organization.organizations.count).to eq(2)
        expect(organization.organizations).to include(organization1, organization2)
      end

      it "member has groups in has_many through associations after adding member to groups" do

        expect(user.groups.size).to eq(0)

        group.add user
        organization.add user

        expect(user.groups.size).to eq(2)
      end

      it "member doesn't have groups in has_many through associations after deleting member from group" do
        group.add user

        expect(user.groups.size).to eq(1)

        user.groups.delete group

        expect(user.groups.size).to eq(0)
      end

      it "doesn't select duplicate groups" do
        group.add user, as: 'manager'
        group.add user, as: 'user'
        classroom.add user

        expect(user.polymorphic_groups.count).to eq(2)
        expect(user.polymorphic_groups.to_a.size).to eq(2)
        expect(user.groups.count).to eq(1)
      end

      it "adds based on membership_type" do
        group.add user
        group.add user, as: 'manager'
        organization.add user
        organization.add user, as: 'owner'

        expect(user.polymorphic_groups.count).to eq(2)
        expect(user.group_memberships_as_member.count).to eq(4)
      end

      it "properly checks group inclusion with complex relationships (Rails 4.2 bug)" do
        parent = Parent.create!
        student1 = Student.create!(id: 1)
        student2 = Student.create!(id: 2)

        student1.add parent
        student2.add parent

        university1 = University.new(id: 11)
        university1.enrollments.build(parent: parent, student: student1)
        university1.save!

        university1.add student1

        university2 = University.new(id: 22)
        university2.enrollments.build(parent: parent, student: student2)
        university2.save!

        university2.add student2

        # Initially, things are as expected

        expect(student1.in_group?(university1)).to eq(true)
        expect(student1.in_group?(university2)).to eq(false)
        expect(student2.in_group?(university1)).to eq(false)
        expect(student2.in_group?(university2)).to eq(true)

        enrolled_students = parent.enrolled_students.to_a.sort_by(&:id)

        expect(enrolled_students[0].id).to eq(1)
        expect(enrolled_students[0].in_group?(university1)).to eq(true)
        expect(enrolled_students[0].in_group?(university2)).to eq(false)

        expect(enrolled_students[1].id).to eq(2)
        expect(enrolled_students[1].in_group?(university1)).to eq(false)
        expect(enrolled_students[1].in_group?(university2)).to eq(true)

        # After getting records fresh from the database, a bug in Rails 4
        # returns the same `exists?` result (inside `in_group?`) for each record.
        #
        # This seems to be a result of some internal cache that retrieves the
        # wrong internal records or values when merging or querying.

        parent = Parent.first
        university2 = University.find(22)

        student2 = Student.find(2)

        results = parent.enrolled_students.map{ |s| [s.id, s.in_group?(university2)]}

        expect(results.sort_by(&:first)).to eq([[1, false], [2, true]])
      end

      it "properly joins on group memberships table when chaining" do
        parent1 = Parent.create!
        student1 = Student.create!

        student1.add parent1

        parent2 = Parent.create!
        student2 = Student.create!

        student2.add parent2

        university1 = University.new
        university1.enrollments.build(parent: parent1, student: student1)
        university1.save!

        university1.add student1, as: :athlete

        university2 = University.new
        university2.enrollments.build(parent: parent1, student: student1)
        university2.enrollments.build(parent: parent2, student: student2)
        university2.save!

        university2.add student1
        university2.add student2, as: :athlete

        expect(University.with_member(parent1.enrolled_students)).to include(university1, university2)

        expect(University.with_members(parent1.enrolled_students).as(:athlete)).to include(university1)
        expect(University.with_members(parent1.enrolled_students).as(:athlete)).to_not include(university2)
      end

      xit "doesn't allow merging associations that don't go through group memberships" do
        expect{ University.with_member(Parent.new.enrolled_students) }.to raise_error(Groupify::ActiveRecord::InvalidAssociationError)
        expect{ University.with_memberships_for_group(criteria: Parent.new.enrolled_students) }.to raise_error(Groupify::ActiveRecord::InvalidAssociationError)
      end
    end
  end
end

describe Groupify::ActiveRecord do
  let(:user) { User.create! }
  let(:group) { Group.create! }
  let(:widget) { Widget.create! }
  let(:namespaced_member) { Namespaced::Member.create! }

  describe "configuration" do
    context "globally configured group and group membership models" do
      before do
        Groupify.configure do |config|
          config.group_class_name = 'CustomGroup'
          config.group_membership_class_name = 'CustomGroupMembership'
        end

        require_relative './active_record/custom_group_membership'
        require_relative './active_record/custom_user'
        require_relative './active_record/custom_group'
      end

      after do
        Groupify.configure do |config|
          config.group_class_name = 'Group'
          config.group_membership_class_name = 'GroupMembership'
        end
      end

      it "uses the custom models to store groups and group memberships" do
        custom_user = CustomUser.create!
        custom_group = CustomGroup.create!
        custom_user.groups << custom_group
        custom_user.named_groups << :test
        expect(GroupMembership.count).to eq(0)
        expect(CustomGroupMembership.count).to eq(2)
      end

      it "correctly queries the custom models for groups" do
        custom_user = CustomUser.create!
        custom_group = CustomGroup.create!
        custom_group.add(custom_user, as: :manager)

        expect(custom_user.in_any_group?(custom_group)).to be true
        expect(CustomUser.in_group(custom_group)).to eq([custom_user])
        expect(CustomUser.in_any_group(custom_group)).to eq([custom_user])
        expect(CustomUser.in_all_groups(custom_group)).to eq([custom_user])
        expect(CustomUser.in_only_groups(custom_group)).to eq([custom_user])
        expect(CustomUser.as(:manager)).to eq([custom_user])

        expect(custom_group.custom_users.as(:manager)).to eq([custom_user])
      end

      it "correctly queries the custom models for named groups" do
        custom_user = CustomUser.create!
        custom_user.named_groups.add(:test_group, as: :observer)
        custom_user.named_groups << :admins

        expect(CustomUser.in_named_group(:test_group)).to eq([custom_user])
        expect(CustomUser.in_named_group(:test_group).as(:observer)).to eq([custom_user])
        expect(CustomUser.in_any_named_group(:test_group, :test)).to eq([custom_user])
        expect(CustomUser.in_all_named_groups(:test_group, :admins)).to eq([custom_user])
        expect(CustomUser.in_only_named_groups(:test_group, :admins)).to eq([custom_user])
        expect(CustomUser.as(:observer)).to eq([custom_user])
      end
    end

    context "member with custom group model" do
      before do
        class CustomProject < ActiveRecord::Base
          groupify :group
        end

        class ProjectMember < ActiveRecord::Base
          groupify :group_member, group_class_name: 'CustomProject'
        end
      end

      it "overrides the default group name on a per-model basis" do
        member = ProjectMember.create!
        member.groups.create!
        expect(member.groups.first).to be_a CustomProject
      end
    end
  end

  context 'when using groups' do
    it "members and groups are empty when initialized" do
      expect(user.groups).to be_empty
      expect(User.new.groups).to be_empty

      expect(Group.new.members).to be_empty
      expect(group.members).to be_empty
    end

    context "when adding" do
      it "adds a group to a member" do
        user.groups << group
        expect(user.groups).to include(group)
        expect(group.members).to include(user)
        expect(group.users).to include(user)
      end

      it "adds a member to a group" do
        expect(user.groups).to be_empty
        group.add user
        expect(user.groups).to include(group)
        expect(group.members).to include(user)
      end

      it "only adds a member to a group once" do
        group.add user
        group.add user
        expect(user.group_memberships_as_member.count).to eq(1)
      end

      it "adds a namespaced member to a group" do
        group.add(namespaced_member)
        expect(group.namespaced_members).to include(namespaced_member)
      end

      it "adds multiple members to a group" do
        group.add(user, widget)
        expect(group.users).to include(user)
        expect(group.widgets).to include(widget)

        users = [User.create!, User.create!]
        group.add(users)
        expect(group.users).to include(*users)
      end

      it "only adds group to member.groups once when added directly to association" do
        user.groups << group
        user.groups << group

        expect(user.groups.count).to eq(1)

        user.groups.reload

        expect(user.groups.count).to eq(1)
      end

      it "only adds member to group.members once when added directly to association" do
        group.members << user
        group.members << user

        expect(group.members.count).to eq(1)

        group.members.reload

        expect(group.members.count).to eq(1)
      end

      xit "only allows members to be added to their configured group type" do
        classroom = Classroom.create!
        expect { classroom.add(user) }.to raise_error(ActiveRecord::AssociationTypeMismatch)
        expect { user.groups << classroom }.to raise_error(ActiveRecord::AssociationTypeMismatch)
      end

      it "allows a group to also act as a member" do
        parent_org = Organization.create!
        child_org = Organization.create!
        parent_org.add(child_org)
        expect(parent_org.organizations).to include(child_org)
      end

      it "can have subclassed associations for groups of a specific kind" do
        org = Organization.create!

        user.groups << group
        user.groups << org

        expect(user.groups).to include(group)
        expect(user.groups).to include(org)

        expect(user.organizations).to_not include(group)
        expect(user.organizations).to include(org)

        expect(org.members).to include(user)
        expect(group.members).to include(user)

        expect(user.organizations.count).to eq(1)
        expect(user.organizations.first).to be_a(Organization)

        expect(user.groups.count).to eq(2)
        expect(user.groups.first).to be_a(Organization)
        expect(user.groups[1]).to be_a(Group)
      end
    end

    it "lists which member classes can belong to this group" do
      expect(group.class.member_classes).to include(User, Widget)
      expect(group.member_classes).to include(User, Widget)

      expect(Organization.member_classes).to include(User, Widget, Manager)
    end

    it "finds members by group" do
      group.add user

      expect(User.in_group(group).first).to eql(user)
    end

    it "finds the group a member belongs to" do
      group.add user

      expect(Group.with_member(user).first).to eq(group)
    end

    context 'when removing' do
      it "removes members from a group" do
        group.add user
        group.add widget

        group.users.delete(user)
        group.widgets.destroy(widget)

        expect(user.groups).to_not include(group)
        expect(widget.groups).to_not include(group)

        expect(group.widgets).to_not include(widget)
        expect(group.users).to_not include(user)

        expect(widget.groups).to_not include(group)
        expect(user.groups).to_not include(group)
      end

      it "removes groups from a member" do
        group.add widget
        group.add user

        user.groups.delete(group)
        widget.groups.destroy(group)

        expect(group.users).to_not include(user)
        expect(group.widgets).to_not include(widget)

        expect(group.widgets).to_not include(widget)
        expect(group.users).to_not include(user)

        expect(widget.groups).to_not include(group)
        expect(user.groups).to_not include(group)
      end

      it "removes the membership relation when a member is destroyed" do
        group.add user
        user.destroy
        expect(group).not_to be_destroyed
        expect(group.users).not_to include(user)
      end

      it "removes the membership relations when a group is destroyed" do
        group.add user
        group.add widget
        group.destroy

        expect(user).not_to be_destroyed
        expect(user.reload.groups).to be_empty

        expect(widget).not_to be_destroyed
        expect(widget.reload.groups).to be_empty
      end
    end

    context "when designating a model as a group and member" do
      it "finds members" do
        member1 = Ambiguous.create!(name: "member1")
        member2 = Ambiguous.create!(name: "member2")
        group1 = Ambiguous.create!(name: "group1")
        group2 = Ambiguous.create!(name: "group2")

        group1.add member1
        group2.add member2, as: 'member'

        expect(group1.members).to include(member1)
        expect(group2.members).to include(member2)

        expect(group2.members.as(:member)).to include(member2)
        expect(member2.groups.as(:member)).to include(group2)

        expect(Ambiguous.as(:member)).to include(member2)
        expect(Ambiguous.as(:member)).to_not include(group2)

        expect(Ambiguous.with_member(member1)).to include(group1)
        expect(Ambiguous.with_member(member1)).to_not include(member1)
        expect(Ambiguous.with_member(member1)).to_not include(member2)
      end
    end

    context 'when checking group membership' do
      it "members can check if they belong to any/all groups" do
        user.groups << group
        group2 = Group.create!
        user.groups << group2
        group3 = Group.create!

        expect(user.groups).to include(group)
        expect(user.groups).to include(group2)

        expect(User.in_group(group).first).to eql(user)
        expect(User.in_group(group2).first).to eql(user)
        expect(user.in_group?(group)).to be true

        expect(User.in_any_group(group).first).to eql(user)
        expect(User.in_any_group(group3)).to be_empty
        expect(user.in_any_group?(group2, group3)).to be true
        expect(user.in_any_group?(group3)).to be false

        expect(User.in_all_groups(group, group2).first).to eql(user)
        expect(User.in_all_groups([group, group2]).first).to eql(user)
        expect(user.in_all_groups?(group, group2)).to be true
        expect(user.in_all_groups?(group, group3)).to be false
      end

      it "members can check if groups are shared" do
        user.groups << group
        widget.groups << group
        user2 = User.create!
        user2.groups << group

        expect(user.shares_any_group?(widget)).to be true
        expect(Widget.shares_any_group(user).to_a).to include(widget)
        expect(User.shares_any_group(widget).to_a).to include(user, user2)

        expect(user.shares_any_group?(user2)).to be true
        expect(User.shares_any_group(user).to_a).to include(user2)
      end

      it "gracefully handles missing groups" do
        expect(user.in_group?(nil)).to be false
      end
    end

    context "when retrieving membership types" do
      it "gets a list of membership types for a group" do
        group.add user, as: :owner
        group.add user, as: :admin

        expect(user.membership_types_for_group(group)).to include(nil, 'owner', 'admin')
      end

      it "gets a list of membership types for a named group" do
        project = Project.create!

        project.named_groups.add :workgroup, as: :owner
        project.named_groups.add :workgroup, as: :admin

        expect(project.membership_types_for_named_group(:workgroup)).to include(nil, 'owner', 'admin')
      end

        it "gets a list of membership types for a member" do
          group.add user, as: :owner
          group.add user, as: :admin

          expect(group.membership_types_for_member(user)).to include(nil, 'owner', 'admin')
        end
    end

    context 'when merging groups' do
      let(:task) { Task.create! }
      let(:manager) { Manager.create! }

      it "moves the members from source to destination and destroys the source" do
        source = Group.create!
        destination = Organization.create!

        source.add(user)
        destination.add(manager)

        destination.merge!(source)
        expect(source.destroyed?).to be true

        expect(destination.users).to include(user, manager)
        expect(destination.managers).to include(manager)
      end

      it "moves membership types" do
        source = Group.create!
        destination = Organization.create!

        source.add(user)
        source.add(manager, as: 'manager')

        destination.merge!(source)
        expect(source.destroyed?).to be true

        expect(destination.users.as(:manager)).to include(manager)
      end

      it "fails to merge if the destination group cannot contain the source group's members" do
        source = Organization.create!
        destination = Group.create!

        source.add(manager)
        destination.add(user)

        # Managers cannot be members of a Group
        expect {destination.merge!(source)}.to raise_error(ArgumentError)
      end

      it "merges incompatible groups as long as all the source members can be moved to the destination" do
        source = Organization.create!
        destination = Group.create!

        source.add(user)
        destination.add(widget)

        expect {destination.merge!(source)}.to_not raise_error

        expect(source.destroyed?).to be true
        expect(destination.users.to_a).to include(user)
        expect(destination.widgets.to_a).to include(widget)
      end
    end

    context "when using membership types with groups" do
      it 'adds groups to a member with a specific membership type' do
        user.group_memberships_as_member.create!(group: group, as: :admin)

        expect(user.groups).to include(group)
        expect(group.members).to include(user)
        expect(group.users).to include(user)

        expect(user.groups.as(:admin)).to include(group)
        expect(group.members).to include(user)
        expect(group.users).to include(user)
      end

      it 'adds members to a group with specific membership types' do
        group.add(user, as: 'manager')
        group.add(widget)

        expect(user.groups).to include(group)
        expect(group.members).to include(user)
        expect(group.members.as(:manager)).to include(user)
        expect(group.users).to include(user)

        expect(group.members).to include(user)
        expect(group.users).to include(user)
      end

      it "adds multiple members to a group with a specific membership type" do
        manager = User.create!
        group.add(user, manager, as: :manager)

        expect(group.users.as(:manager)).to include(user, manager)
      end

      it "finds members by membership type" do
        group.add user, as: 'manager'
        expect(User.as(:manager)).to include(user)
      end

      it "finds members by multiple membership types" do
        organization = Organization.create!
        classroom = Classroom.create!

        organization.add user, as: 'manager'
        organization.add user, as: 'employee'
        classroom.add user, as: 'teacher'
        group.add user, as: 'manager'

        expect(User.as(:teacher, :manager)).to include(user)
        expect(User.as(:teacher, :employee)).to include(user)
        expect(user.polymorphic_groups.as(:manager, :employee)).to include(organization, group)
        expect(user.polymorphic_groups.as(:manager, :employee)).to_not include(classroom)
        expect(user.polymorphic_groups.as(:teacher, :manager)).to include(classroom, organization, group)
      end

      it "finds members by group with membership type" do
        group.add user, as: 'employee'

        expect(User.in_group(group).as('employee').first).to eql(user)
      end

      it "finds the group a member belongs to with a membership type" do
        group.add user, as: :manager
        user.groups.create!

        expect(Group.with_member(user).as(:manager)).to eq([group])
      end

      it "checks if members belong to any groups with a certain membership type" do
        group2 = Group.create!
        user.group_memberships_as_member.create!([{group: group, as: 'employee'}, {group: group2}])

        expect(User.in_any_group(group, group2).as('employee').first).to eql(user)
      end

      it "still returns a unique list of groups for the member" do
        group.add user, as: 'manager'
        expect(user.groups.size).to eq(1)
        expect(group.users.size).to eq(1)
        expect(group.members.size).to eq(1)
      end

      it "checks if members belong to all groups with a certain membership type" do
        group2 = Group.create!
        group3 = Group.create!
        group4 = Group.create!
        group.add(user, as: 'employee')
        group2.add(user, as: 'employee')
        group3.add(user, as: 'contractor')

        expect(User.in_all_groups(group, group2, group3)).to match_array([user])
        expect(User.in_all_groups(group, group2, group3, group4)).to be_empty
        expect(User.in_all_groups(group, group2).as('employee').first).to eql(user)
        expect(User.in_all_groups([group, group2]).as('employee').first).to eql(user)
        expect(User.in_all_groups(group, group3).as('employee')).to be_empty

        expect(user.in_all_groups?(group, group2, group3)).to be true
        expect(user.in_all_groups?(group, group2, as: :employee)).to be true
        expect(user.in_all_groups?(group, group3, as: 'employee')).to be false
      end

      xit "checks if members belong to only groups with a certain membership type" do
        group2 = Group.create!
        group3 = Group.create!
        group4 = Group.create!
        group.add(user)
        group2.add(user, as: 'employee')
        group3.add(user, as: 'contractor')
        group4.add(user, as: 'employee')

        expect(User.in_only_groups(group, group2, group3, group4)).to match_array([user])
        expect(User.in_only_groups(group, group2, group4)).to be_empty

        expect(User.in_only_groups(group2, group4).as('employee').first).to eql(user)
        expect(User.in_only_groups([group, group2]).as('employee')).to be_empty
        expect(User.in_only_groups(group, group2, group3, group4).as('employee')).to be_empty

        expect(user.in_only_groups?(group, group2, group3, group4)).to be true
        expect(user.in_only_groups?(group2, group4, as: 'employee')).to be true
        expect(user.in_only_groups?(group, group2, as: 'employee')).to be false
        expect(user.in_only_groups?(group, group2, group3, group4, as: 'employee')).to be false
      end

      it "members can check if groups are shared with the same membership type" do
        user2 = User.create!
        group.add(user, user2, widget, as: "Sub Group #1")

        expect(user.shares_any_group?(widget, as: "Sub Group #1")).to be true
        expect(Widget.shares_any_group(user).as("Sub Group #1").to_a).to include(widget)
        expect(User.shares_any_group(widget).as("Sub Group #1").to_a).to include(user, user2)

        expect(user.shares_any_group?(user2, as: "Sub Group #1")).to be true
        expect(User.shares_any_group(user).as("Sub Group #1").to_a).to include(user2)
      end

      context "when removing" do
        before(:each) do
          group.add user, as: 'employee'
          group.add user, as: 'manager'
        end

        it "removes all membership types when removing a member from a group" do
          group.add user

          group.users.destroy(user)

          expect(user.groups).to_not include(group)
          expect(user.groups.as('manager')).to_not include(group)
          expect(user.groups.as('employee')).to_not include(group)
          expect(group.users).to_not include(user)
        end

        it "removes a specific membership type from the member side" do
          user.groups.destroy(group, as: 'manager')
          expect(user.groups.as('manager')).to be_empty
          expect(user.groups.as('employee')).to include(group)
          expect(user.groups).to include(group)
        end

        it "removes a specific membership type from the group side" do
          group.users.delete(user, as: :manager)
          expect(user.groups.as('manager')).to be_empty
          expect(user.groups.as('employee')).to include(group)
          expect(user.groups).to include(group)
        end

        it "retains the member in the group if all membership types have been removed" do
          group.users.destroy(user, as: 'manager')
          user.groups.delete(group, as: 'employee')
          expect(user.groups).to include(group)
        end
      end
    end
  end

  context 'when using named groups' do
    before(:each) do
      user.named_groups.concat :admin, :user, :poster
    end

    it "enforces uniqueness" do
      user.named_groups << :admin
      expect(user.named_groups.count{|g| g == :admin}).to eq(1)
    end

    it "queries named groups" do
      expect(user.named_groups).to include(:user, :admin)
    end

    it "removes named groups" do
      user.named_groups.delete(:admin, :poster)
      expect(user.named_groups).to include(:user)
      expect(user.named_groups).to_not include(:admin, :poster)

      user.named_groups.destroy(:user)
      expect(user.named_groups).to be_empty
    end

    it "removes all named groups" do
      user.named_groups.destroy_all
      expect(user.named_groups).to be_empty
    end

    it "works when using only named groups and not groups" do
      project = Project.create!
      project.named_groups.add(:accounting)
      expect(project.named_groups).to include(:accounting)
      project.named_groups.delete_all
      expect(project.named_groups).to be_empty
    end

    it "checks if a member belongs to one named group" do
      expect(user.in_named_group?(:admin)).to be true
      expect(User.in_named_group(:admin).first).to eql(user)
    end

    it "checks if a member belongs to any named group" do
      expect(user.in_any_named_group?(:admin, :user, :test)).to be true
      expect(user.in_any_named_group?(:foo, :bar)).to be false

      expect(User.in_any_named_group(:admin, :test).first).to eql(user)
      expect(User.in_any_named_group(:test)).to be_empty
    end

    it "checks if a member belongs to all named groups" do
      expect(user.in_all_named_groups?(:admin, :user)).to be true
      expect(user.in_all_named_groups?(:admin, :user, :test)).to be false
      expect(User.in_all_named_groups(:admin, :user).first).to eql(user)
    end

    it "checks if a member belongs to only certain named groups" do
      expect(user.in_only_named_groups?(:admin, :user, :poster)).to be true
      expect(user.in_only_named_groups?(:admin, :user, :poster, :foo)).to be false
      expect(user.in_only_named_groups?(:admin, :user)).to be false
      expect(user.in_only_named_groups?(:admin, :user, :test)).to be false

      expect(User.in_only_named_groups(:admin, :user, :poster).first).to eql(user)
      expect(User.in_only_named_groups(:admin, :user, :poster, :foo)).to be_empty
      expect(User.in_only_named_groups(:admin)).to be_empty
    end

    it "checks if named groups are shared" do
      user2 = User.create!(:named_groups => [:admin])

      expect(user.shares_any_named_group?(user2)).to be true
      expect(User.shares_any_named_group(user).to_a).to include(user2)
    end

    context 'and using membership types with named groups' do
      before(:each) do
        user.named_groups.concat :team1, :team2, as: 'employee'
        user.named_groups.push :team3, as: 'manager'
        user.named_groups.push :team1, as: 'developer'
      end

      it "queries named groups, filtering by membership type" do
        expect(user.named_groups).to include(:team1, :team2, :team3)
        expect(user.named_groups.as('manager')).to eq([:team3])
      end

      it "enforces uniqueness of named groups" do
        user.named_groups << :team1
        expect(user.named_groups.count{|g| g == :team1}).to eq(1)
        expect(user.group_memberships_as_member.where(group_name: :team1, membership_type: nil).count).to eq(1)
        expect(user.group_memberships_as_member.where(group_name: :team1, membership_type: 'employee').count).to eq(1)
        expect(user.named_groups.as('employee').count{|g| g == :team1}).to eq(1)
      end

      it "enforces uniqueness of group name and membership type for group memberships" do
        user.named_groups.push :team1, as: 'employee'
        expect(user.group_memberships_as_member.where(group_name: :team1, membership_type: nil).count).to eq(1)
        expect(user.group_memberships_as_member.where(group_name: :team1, membership_type: 'employee').count).to eq(1)
        expect(user.named_groups.count{|g| g == :team1}).to eq(1)
        expect(user.named_groups.as('employee').count{|g| g == :team1}).to eq(1)
      end

      it "checks if a member belongs to one named group with a certain membership type" do
        expect(user.in_named_group?(:team1, as: 'employee')).to be true
        expect(User.in_named_group(:team1).as('employee').first).to eql(user)
      end

      it "checks if a member belongs to any named group with a certain membership type" do
        expect(user.in_any_named_group?(:team1, :team3, as: 'employee')).to be true
        expect(User.in_any_named_group(:team2, :team3).as('manager').first).to eql(user)
      end

      it "checks if a member belongs to all named groups with a certain membership type" do
        expect(user.in_all_named_groups?(:team1, :team2, as: 'employee')).to be true
        expect(user.in_all_named_groups?(:team1, :team3, as: 'employee')).to be false
        expect(User.in_all_named_groups(:team1, :team2).as('employee').first).to eql(user)
      end

      xit "checks if a member belongs to only certain named groups with a certain membership type" do
        expect(user.in_only_named_groups?(:team1, :team2, as: 'employee')).to be true
        expect(user.in_only_named_groups?(:team1, as: 'employee')).to be false
        expect(user.in_only_named_groups?(:team1, :team3, as: 'employee')).to be false
        expect(user.in_only_named_groups?(:foo, as: 'employee')).to be false

        expect(User.in_only_named_groups(:team1, :team2).as('employee').first).to eql(user)
        expect(User.in_only_named_groups(:team1).as('employee')).to be_empty
        expect(User.in_only_named_groups(:foo).as('employee')).to be_empty
      end

      it "checks if a member shares any named groups with a certain membership type" do
        project = Project.create!(:named_groups => [:team3])

        expect(user.shares_any_named_group?(project, as: 'manager')).to be true
        expect(User.shares_any_named_group(project).as('manager').to_a).to include(user)
      end

      it "removes named groups with a certain membership type" do
        user.named_groups.delete(:team1, as: :employee)
        expect(user.named_groups.as(:employee)).to include(:team2)
        expect(user.named_groups.as(:employee)).to_not include(:team1)
        expect(user.named_groups.as(:developer)).to include(:team1)
        expect(user.named_groups).to include(:team1)
      end

      it "removes all named group memberships if membership type is not specified" do
        user.named_groups.destroy(:team1)
        expect(user.named_groups).to_not include(:team1)
        expect(user.named_groups.as(:employee)).to_not include(:team1)
        expect(user.named_groups.as(:developer)).to_not include(:team1)
        expect(user.named_groups.as(:employee)).to include(:team2)
      end

      it "finds all named group memberships for multiple membership types" do
        expect(user.named_groups.as(:manager, :developer)).to include(:team3, :team1)
        expect(user.named_groups.as(:manager, :developer)).to_not include(:team2)
      end
    end
  end
end
