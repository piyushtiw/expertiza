class Questionnaire < ActiveRecord::Base
  # for doc on why we do it this way,
  # see http://blog.hasmanythrough.com/2007/1/15/basic-rails-association-cardinality
  has_many :questions, dependent: :destroy # the collection of questions associated with this Questionnaire
  belongs_to :instructor # the creator of this questionnaire
  has_many :assignment_questionnaires, dependent: :destroy
  has_many :assignments, through: :assignment_questionnaires
  has_one :questionnaire_node, foreign_key: 'node_object_id', dependent: :destroy

  validate :validate_questionnaire
  validates :name, presence: true
  validates :max_question_score, :min_question_score, numericality: true

  DEFAULT_MIN_QUESTION_SCORE = 0  # The lowest score that a reviewer can assign to any questionnaire question
  DEFAULT_MAX_QUESTION_SCORE = 5  # The highest score that a reviewer can assign to any questionnaire question
  DEFAULT_QUESTIONNAIRE_URL = "http://www.courses.ncsu.edu/csc517".freeze
  QUESTIONNAIRE_TYPES = ['ReviewQuestionnaire',	
                         'MetareviewQuestionnaire',	
                         'Author FeedbackQuestionnaire',	
                         'AuthorFeedbackQuestionnaire',	
                         'Teammate ReviewQuestionnaire',	
                         'TeammateReviewQuestionnaire',	
                         'SurveyQuestionnaire',	
                         'AssignmentSurveyQuestionnaire',	
                         'Assignment SurveyQuestionnaire',	
                         'Global SurveyQuestionnaire',	
                         'GlobalSurveyQuestionnaire',	
                         'Course SurveyQuestionnaire',	
                         'CourseSurveyQuestionnaire',	
                         'BookmarkratingQuestionnaire',	
                         'QuizQuestionnaire'].freeze
  has_paper_trail

  def get_weighted_score(assignment, scores)
    # create symbol for "varying rubrics" feature -Yang
    round = AssignmentQuestionnaire.find_by(assignment_id: assignment.id, questionnaire_id: self.id).used_in_round
    questionnaire_symbol = if !round.nil?
                             (self.symbol.to_s + round.to_s).to_sym
                           else
                             self.symbol
                           end
    compute_weighted_score(questionnaire_symbol, assignment, scores)
  end

  def compute_weighted_score(symbol, assignment, scores)
    aq = self.assignment_questionnaires.find_by(assignment_id: assignment.id)
    if !scores[symbol][:scores][:avg].nil?
      scores[symbol][:scores][:avg] * aq.questionnaire_weight / 100.0
    else
      0
    end
  end

  # Does this questionnaire contain true/false questions?
  def true_false_questions?
    questions.each {|question| return true if question.type == "Checkbox" }
    false
  end

  def delete
    self.assignments.each do |assignment|
      raise "The assignment #{assignment.name} uses this questionnaire.
            Do you want to <A href='../assignment/delete/#{assignment.id}'>delete</A> the assignment?"
    end

    self.questions.each(&:delete)

    node = QuestionnaireNode.find_by(node_object_id: self.id)
    node.destroy if node

    self.destroy
  end

  def max_possible_score
    results = Questionnaire.joins('INNER JOIN questions ON questions.questionnaire_id = questionnaires.id')
                           .select('SUM(questions.weight) * questionnaires.max_question_score as max_score')
                           .where('questionnaires.id = ?', self.id)
    results[0].max_score
  end

  # validate the entries for this questionnaire
  def validate_questionnaire
    errors.add(:max_question_score, "The maximum question score must be a positive integer.") if max_question_score < 1
    errors.add(:min_question_score, "The minimum question score must be less than the maximum") if min_question_score >= max_question_score

    results = Questionnaire.where("id <> ? and name = ? and instructor_id = ?", id, name, instructor_id)
    errors.add(:name, "Questionnaire names must be unique.") if results.present?
  end

# This method will be called in controller to create the questionnaire
  class << self
    def create_new_questionnaire_obj(params, session)
      # Assigning values passed from UI in params[:id] to questionnaire object
      if Questionnaire::QUESTIONNAIRE_TYPES.include? params[:questionnaire][:type]
        questionnaire = Object.const_get(params[:questionnaire][:type]).new 
        questionnaire.private = params[:questionnaire][:private] == 'true'
        questionnaire.name = params[:questionnaire][:name]
        questionnaire.instructor_id = session[:user].id
        questionnaire.min_question_score = params[:questionnaire][:min_question_score]
        questionnaire.max_question_score = params[:questionnaire][:max_question_score]
        questionnaire.type = params[:questionnaire][:type]
        # Zhewei: Right now, the display_type in 'questionnaires' table and name in 'tree_folders' table are not consistent.
        # In the future, we need to write migration files to make them consistency.
        questionnaire.display_type = display_type_for_questionnaire(params)
        questionnaire.instruction_loc = Questionnaire::DEFAULT_QUESTIONNAIRE_URL
        
        if questionnaire.save
          create_questionnaire_node(questionnaire)
        end
        # returning the questionnaire obejct to calling method create in controller
        questionnaire 
      else
        false
      end
    end

    private

# This method is used to create Treenode for newly created questionnaire
      def create_questionnaire_node(questionnaire)
        tree_folder = TreeFolder.where(['name like ?', questionnaire.display_type]).first
        parent = FolderNode.find_by(node_object_id: tree_folder.id)
        QuestionnaireNode.create(parent_id: parent.id, node_object_id: questionnaire.id, type: 'QuestionnaireNode')
      end
      
 # Displaying the newly created questionnaire
      def display_type_for_questionnaire(params)
        display_type = params[:questionnaire][:type].split('Questionnaire')[0]
        
        case display_type
        when 'AuthorFeedback'
          display_type = 'Author%Feedback'
        when 'CourseSurvey'
          display_type = 'Course%Survey'
        when 'TeammateReview'
          display_type = 'Teammate%Review'
        when 'GlobalSurvey'
          display_type = 'Global%Survey'
        when 'AssignmentSurvey'
          display_type = 'Assignment%Survey'
        end

        display_type
      end
  end
end
