class QuestionnairesController < ApplicationController
  # Controller for Questionnaire objects
  # A Questionnaire can be of several types (QuestionnaireType)
  # Each Questionnaire contains zero or more questions (Question)
  # Generally a questionnaire is associated with an assignment (Assignment)

  before_action :authorize

  MINIMUM_QUESTION_SCORE = 0
  MAXIMUM_QUESTION_SCORE = 1
  QUESTION_MAX_LABEL = 'Strongly agree'
  QUESTION_MIN_LABEL = 'Strongly disagree'
  CRITERION_QUESTION_SIZE = '50, 3'
  DROPDOWN_SCALE = '0|1|2|3|4|5'
  TEXT_AREA_SIZE = '60, 5'
  TEXT_FIELD_SIZE = '30'
  # Check role access for edit questionnaire
  def action_allowed?
    if params[:action] == "edit"
      @questionnaire = Questionnaire.find(params[:id])
      (['Super-Administrator',
        'Administrator'].include? current_role_name) ||
          ((['Instructor'].include? current_role_name) && current_user_id?(@questionnaire.try(:instructor_id))) ||
          ((['Teaching Assistant'].include? current_role_name) && assign_instructor_id == @questionnaire.try(:instructor_id))

    else
      # refactor
      ['Super-Administrator',
       'Administrator',
       'Instructor',
       'Teaching Assistant', 'Student'].include? current_role_name
    end
  end

  # Create a clone of the given questionnaire, copying all associated
  # questions. The name and creator are updated.
  def copy
    orig_questionnaire = Questionnaire.find(params[:id])
    questions = Question.where(questionnaire_id: params[:id])
    @questionnaire = orig_questionnaire.dup
    @questionnaire.instructor_id = session[:user].instructor_id ## Why was TA-specific code removed here?  See Project E713.
    copy_questionnaire_details(questions, orig_questionnaire)
  end

  def view
    @questionnaire = Questionnaire.find(params[:id])
  end

  def new
    begin
      @questionnaire = Object.const_get(params[:model].split.join).new if Questionnaire::QUESTIONNAIRE_TYPES.include? params[:model]
    rescue StandardError
      flash[:error] = $ERROR_INFO
    end
  end

  def create
    # if questionnaire has name create new questionnaire
    # Create questionnaire node for new questionnaire
    if questionnaire_has_name?
      questionnaire = Questionnaire.create_new_questionnaire_obj(params, session)
      flash[:success] = 'You have successfully created a questionnaire!'
      redirect_to controller: 'questionnaires', action: 'edit', id: questionnaire.id
    else
      flash[:error] = 'A rubric or survey must have a title.'
      redirect_to controller: 'questionnaires',
        action: 'new',
        model: params[:questionnaire][:type],
        private: params[:questionnaire][:private]
    end
  end

  # Edit a questionnaire
  def edit
    @questionnaire = Questionnaire.find(params[:id])
    redirect_to Questionnaire if @questionnaire.nil?
    session[:return_to] = request.original_url
  end

  def update
    # If 'Add' or 'Edit/View advice' is clicked, redirect appropriately
    if params[:add_new_questions]
      redirect_to action: 'add_new_questions', id: params[:id], question: params[:new_question]
    elsif params[:view_advice]
      redirect_to controller: 'advice', action: 'edit_advice', id: params[:id]
    else
      @questionnaire = Questionnaire.find(params[:id])
      begin
        # Save questionnaire information
        @questionnaire.update_attributes(questionnaire_params)

        # Save all questions
        unless params[:question].nil?
          params[:question].each_pair do |k, v|
            @question = Question.find(k)
            # example of 'v' value
            # {"seq"=>"1.0", "txt"=>"WOW", "weight"=>"1", "size"=>"50,3", "max_label"=>"Strong agree", "min_label"=>"Not agree"}
            v.each_pair do |key, value|
              @question.send(key + '=', value) if @question.send(key) != value
            end
            @question.save
          end
        end
        flash[:success] = 'The questionnaire has been successfully updated!'
      rescue StandardError
        flash[:error] = $ERROR_INFO
      end
      redirect_to action: 'edit', id: @questionnaire.id.to_s.to_sym
    end
  end

  # Remove a given questionnaire
  def delete
    @questionnaire = Questionnaire.find(params[:id])
    if @questionnaire
      begin
        name = @questionnaire.name
        # if this rubric is used by some assignment, flash error
        unless @questionnaire.assignments.empty?
          raise "The assignment <b>#{@questionnaire.assignments.first.try(:name)}</b> uses this questionnaire. Are sure you want to delete the assignment?"
        end
        questions = @questionnaire.questions
        # if this rubric had some answers, flash error
        questions.each do |question|
          raise "There are responses based on this rubric, we suggest you do not delete it." unless question.answers.empty?
        end

        # delete all questions and QuestionnaireNode
        # related to questionnaire with dependent destroy property
        @questionnaire.delete
        undo_link("The questionnaire \"#{name}\" has been successfully deleted.")
      rescue StandardError => e
        flash[:error] = e.message
      end
    end
    redirect_to action: 'list', controller: 'tree_display'
  end

  # Toggle the access permission for this assignment from public to private, or vice versa
  def toggle_access
    @questionnaire = Questionnaire.find(params[:id])
    @questionnaire.private = !@questionnaire.private
    @questionnaire.save
    @access = @questionnaire.private == true ? "private" : "public"
    undo_link("the questionnaire \"#{@questionnaire.name}\" has been successfully made #{@access}. ")
    redirect_to controller: 'tree_display', action: 'list'
  end

  # Zhewei: This method is used to add new questions when editing questionnaire.
  def add_new_questions
    questionnaire_id = params[:id] unless params[:id].nil?
    num_of_existed_questions = Questionnaire.find(questionnaire_id).questions.size
    ((num_of_existed_questions + 1)..(num_of_existed_questions + params[:question][:total_num].to_i)).each do |i|
      question = Object.const_get(params[:question][:type]).create(txt: '', questionnaire_id: questionnaire_id, seq: i, type: params[:question][:type], break_before: true)
      if question.is_a? ScoredQuestion
        question.weight = MAXIMUM_QUESTION_SCORE
        question.max_label = QUESTION_MIN_LABEL
        question.min_label = QUESTION_MAX_LABEL
      end
      question.size = CRITERION_QUESTION_SIZE if question.is_a? Criterion
      question.alternatives = DROPDOWN_SCALE if question.is_a? Dropdown
      question.size = TEXT_AREA_SIZE if question.is_a? TextArea
      question.size = TEXT_FIELD_SIZE if question.is_a? TextField
      begin
        question.save
      rescue StandardError
        flash[:error] = $ERROR_INFO
      end
    end
    redirect_to action: 'edit', id: questionnaire_id
  end

  #=========================================================================================================
  # Separate methods for quiz questionnaire
  #=========================================================================================================
  # View a quiz questionnaire
  def view_quiz
    @questionnaire = Questionnaire.find(params[:id])
    @participant = Participant.find(params[:pid]) # creating an instance variable since it needs to be sent to submitted_content/edit
    render :view
  end

  # define a new quiz questionnaire
  # method invoked by the view
  def new_quiz
    valid_request = true
    @assignment_id = params[:aid] # creating an instance variable to hold the assignment id
    @participant_id = params[:pid] # creating an instance variable to hold the participant id
    assignment = Assignment.find(@assignment_id)
    if !assignment.require_quiz? # flash error if this assignment does not require quiz
      flash[:error] = "This assignment does not support the quizzing feature."
      valid_request = false
    else
      team = AssignmentParticipant.find(@participant_id).team

      if team.nil? # flash error if this current participant does not have a team
        flash[:error] = "You should create or join a team first."
        valid_request = false
      else
        if assignment.topics? && team.topic.nil? # flash error if this assignment has topic but current team does not have a topic
          flash[:error] = "Your team should have a topic."
          valid_request = false
        end
      end
    end

    if valid_request && Questionnaire::QUESTIONNAIRE_TYPES.include?(params[:model])
      @questionnaire = Object.const_get(params[:model]).new
      @questionnaire.private = params[:private]
      @questionnaire.min_question_score = MINIMUM_QUESTION_SCORE
      @questionnaire.max_question_score = MAXIMUM_QUESTION_SCORE

      render :new_quiz
    else
      redirect_to controller: 'submitted_content', action: 'view', id: params[:pid]
    end
  end

  # seperate method for creating a quiz questionnaire because of differences in permission
  def create_quiz_questionnaire
    valid = valid_quiz
    if valid.eql?("valid")
      update_questionnaire_instructor
    else
      flash[:error] = valid.to_s
      redirect_to :back
    end
  end

  # edit a quiz questionnaire
  def edit_quiz
    @questionnaire = Questionnaire.find(params[:id])
    if !@questionnaire.taken_by_anyone?
      render :edit
    else
      flash[:error] = "Your quiz has been taken by some other students, you cannot edit it anymore."
      redirect_to controller: 'submitted_content', action: 'view', id: params[:pid]
    end
  end

  # save an updated quiz questionnaire to the database
  def update_quiz
    @questionnaire = Questionnaire.find(params[:id])
    if @questionnaire.nil?
      redirect_to controller: 'submitted_content', action: 'view', id: params[:pid]
      return
    end
    if params['save'] && params[:question].try(:keys)
      @questionnaire.update_attributes(questionnaire_params)

      params[:question].keys.each do |qid|
        @question = Question.find(qid)
        @question.txt = params[:question][qid.to_sym][:txt]
        @question.save

        @quiz_question_choices = QuizQuestionChoice.where(question_id: qid)
        i = 1
        @quiz_question_choices.each do |quiz_question_choice|
          if @question.type == "MultipleChoiceCheckbox"
            if params[:quiz_question_choices][@question.id.to_s][@question.type][i.to_s]
              quiz_question_choice.update_attributes(iscorrect: params[:quiz_question_choices][@question.id.to_s][@question.type][i.to_s][:iscorrect], txt: params[:quiz_question_choices][@question.id.to_s][@question.type][i.to_s][:txt])
            else
              quiz_question_choice.update_attributes(iscorrect: '0', txt: params[:quiz_question_choices][quiz_question_choice.id.to_s][:txt])
            end
          end
          if @question.type == "MultipleChoiceRadio"
            if params[:quiz_question_choices][@question.id.to_s][@question.type][:correctindex] == i.to_s
              quiz_question_choice.update_attributes(iscorrect: '1', txt: params[:quiz_question_choices][@question.id.to_s][@question.type][i.to_s][:txt])
            else
              quiz_question_choice.update_attributes(iscorrect: '0', txt: params[:quiz_question_choices][@question.id.to_s][@question.type][i.to_s][:txt])
            end
          end
          if @question.type == "TrueFalse"
            if params[:quiz_question_choices][@question.id.to_s][@question.type][1.to_s][:iscorrect] == "True" # the statement is correct
              if quiz_question_choice.txt == "True"
                quiz_question_choice.update_attributes(iscorrect: '1') # the statement is correct so "True" is the right answer
              else
                quiz_question_choice.update_attributes(iscorrect: '0')
              end
            else # the statement is not correct
              if quiz_question_choice.txt == "True"
                quiz_question_choice.update_attributes(iscorrect: '0')
              else
                quiz_question_choice.update_attributes(iscorrect: '1') # the statement is not correct so "False" is the right answer
              end
            end
          end

          i += 1
        end
      end
    end
    redirect_to controller: 'submitted_content', action: 'view', id: params[:pid]
  end

  def valid_quiz
    num_quiz_questions = Assignment.find(params[:aid]).num_quiz_questions
    valid = "valid"

    (1..num_quiz_questions).each do |i|
      if params[:questionnaire][:name] == ""
        # questionnaire name is not specified
        valid = "Please specify quiz name (please do not use your name or id)."
        break
      elsif !params.key?(:question_type) || !params[:question_type].key?(i.to_s) || params[:question_type][i.to_s][:type].nil?
        # A type isnt selected for a question
        valid = "Please select a type for each question"
        break
      else
        @new_question = Object.const_get(params[:question_type][i.to_s][:type]).create(txt: '', type: params[:question_type][i.to_s][:type], break_before: true)
        @new_question.update_attributes(txt: params[:new_question][i.to_s])
        type = params[:question_type][i.to_s][:type]
        choice_info = params[:new_choices][i.to_s][type] # choice info for one question of its type
        if choice_info.nil?
          valid = "Please select a correct answer for all questions"
          break
        else
          valid = @new_question.isvalid(choice_info)
          break if valid != "valid"
        end
      end
    end
    valid
  end

  private

  # save questionnaire object after create or edit
  def save
    @questionnaire.save!

    save_questions @questionnaire.id if !@questionnaire.id.nil? and @questionnaire.id > 0
    # We do not create node for quiz questionnaires
    if @questionnaire.type != "QuizQuestionnaire"
      p_folder = TreeFolder.find_by(name: @questionnaire.display_type)
      parent = FolderNode.find_by(node_object_id: p_folder.id)
      # create_new_node_if_necessary(parent)
    end
    undo_link("Questionnaire \"#{@questionnaire.name}\" has been updated successfully. ")
  end

  # save questions that have been added to a questionnaire
  def save_new_questions(questionnaire_id)
    if params[:new_question]
      # The new_question array contains all the new questions
      # that should be saved to the database
      params[:new_question].keys.each do |question_key|
        q = Question.new
        q.txt = params[:new_question][question_key]
        q.questionnaire_id = questionnaire_id
        q.type = params[:question_type][question_key][:type]
        q.seq = question_key.to_i
        if @questionnaire.type == "QuizQuestionnaire"
          q.weight = 1 # setting the weight to 1 for quiz questionnaire since the model validates this field
        end
        q.save unless q.txt.strip.empty?
      end
    end
  end

  # delete questions from a questionnaire
  # @param [Object] questionnaire_id
  def delete_questions(questionnaire_id)
    # Deletes any questions that, as a result of the edit, are no longer in the questionnaire
    questions = Question.where("questionnaire_id = ?", questionnaire_id)
    @deleted_questions = []
    questions.each do |question|
      should_delete = true
      unless question_params.nil?
        params[:question].each_key do |question_key|
          should_delete = false if question_key.to_s == question.id.to_s
        end
      end

      next unless should_delete
      question.question_advices.each(&:destroy)
      # keep track of the deleted questions
      @deleted_questions.push(question)
      question.destroy
    end
  end

  # Handles questions whose wording changed as a result of the edit
  # @param [Object] questionnaire_id
  def save_questions(questionnaire_id)
    delete_questions questionnaire_id
    save_new_questions questionnaire_id

    if params[:question]
      params[:question].keys.each do |question_key|
        if params[:question][question_key][:txt].strip.empty?
          # question text is empty, delete the question
          Question.delete(question_key)
        else
          # Update existing question.
          question = Question.find(question_key)
          Rails.logger.info(question.errors.messages.inspect) unless question.update_attributes(params[:question][question_key])
        end
      end
    end
  end

  # method to save the choices associated with a question in a quiz to the database
  # only for quiz questionnaire
  def save_choices(questionnaire_id)
    # return unless params[:new_question] or params[:new_choices]
    questions = Question.where(questionnaire_id: questionnaire_id)
    question_num = 1

    questions.each do |question|
      q_type = params[:question_type][question_num.to_s][:type]
      params[:new_choices][question_num.to_s][q_type].keys.each do |choice_key|
        score = if params[:new_choices][question_num.to_s][q_type][choice_key]["weight"] == 1.to_s
                  MAXIMUM_QUESTION_SCORE
                else
                  MINIMUM_QUESTION_SCORE
                end
        if q_type == "MultipleChoiceCheckbox"
          q = if params[:new_choices][question_num.to_s][q_type][choice_key][:iscorrect] == 1.to_s
                QuizQuestionChoice.new(txt: params[:new_choices][question_num.to_s][q_type][choice_key][:txt], iscorrect: "true", question_id: question.id)
              else
                QuizQuestionChoice.new(txt: params[:new_choices][question_num.to_s][q_type][choice_key][:txt], iscorrect: "false", question_id: question.id)
              end
          q.save
        elsif q_type == "TrueFalse"
          if params[:new_choices][question_num.to_s][q_type][1.to_s][:iscorrect] == choice_key
            q = QuizQuestionChoice.new(txt: "True", iscorrect: "true", question_id: question.id)
            q.save
            q = QuizQuestionChoice.new(txt: "False", iscorrect: "false", question_id: question.id)
            q.save
          else
            q = QuizQuestionChoice.new(txt: "True", iscorrect: "false", question_id: question.id)
            q.save
            q = QuizQuestionChoice.create(txt: "False", iscorrect: "true", question_id: question.id)
            q.save
          end
        else
          q = if params[:new_choices][question_num.to_s][q_type][1.to_s][:iscorrect] == choice_key
                QuizQuestionChoice.new(txt: params[:new_choices][question_num.to_s][q_type][choice_key][:txt], iscorrect: "true", question_id: question.id)
              else
                QuizQuestionChoice.new(txt: params[:new_choices][question_num.to_s][q_type][choice_key][:txt], iscorrect: "false", question_id: question.id)
              end
          q.save
        end
      end
      question_num += 1
      question.weight = 1
    end
  end

  def questionnaire_params
    params.require(:questionnaire).permit(:name, :instructor_id, :private, :min_question_score,
                                          :max_question_score, :type, :display_type, :instruction_loc)
  end

  def question_params
    params.require(:question).permit(:txt, :weight, :questionnaire_id, :seq, :type, :size,
                                     :alternatives, :break_before, :max_label, :min_label)
  end

  # FIXME: These private methods belong in the Questionnaire model

  def export
    @questionnaire = Questionnaire.find(params[:id])

    csv_data = QuestionnaireHelper.create_questionnaire_csv @questionnaire, session[:user].name

    send_data csv_data,
              type: 'text/csv; charset=iso-8859-1; header=present',
              disposition: "attachment; filename=questionnaires.csv"
  end

  def import
    @questionnaire = Questionnaire.find(params[:id])

    file = params['csv']

    @questionnaire.questions << QuestionnaireHelper.get_questions_from_csv(@questionnaire, file)
  end

  # clones the contents of a questionnaire, including the questions and associated advice
  def copy_questionnaire_details(questions, orig_questionnaire)
    @questionnaire.instructor_id = assign_instructor_id
    @questionnaire.name = 'Copy of ' + orig_questionnaire.name
    begin
      @questionnaire.created_at = Time.now
      @questionnaire.save!
      questions.each do |question|
        new_question = question.dup
        new_question.questionnaire_id = @questionnaire.id
        new_question.size = '50,3' if (new_question.is_a? Criterion or new_question.is_a? TextResponse) and new_question.size.nil?
        new_question.save!
        advices = QuestionAdvice.where(question_id: question.id)
        next if advices.empty?
        advices.each do |advice|
          new_advice = advice.dup
          new_advice.question_id = new_question.id
          new_advice.save!
        end
      end

      p_folder = TreeFolder.find_by(name: @questionnaire.display_type)
      parent = FolderNode.find_by(node_object_id: p_folder.id)
      QuestionnaireNode.find_or_create_by(parent_id: parent.id, node_object_id: @questionnaire.id)
      undo_link("Copy of questionnaire #{orig_questionnaire.name} has been created successfully.")
      redirect_to controller: 'questionnaires', action: 'view', id: @questionnaire.id
    rescue StandardError
      flash[:error] = 'The questionnaire was not able to be copied. Please check the original course for missing information.' + $ERROR_INFO
      redirect_to action: 'list', controller: 'tree_display'
    end
  end

  def assign_instructor_id
    # if the user to copy the questionnaire is a TA, the instructor should be the owner instead of the TA
    if session[:user].role.name != "Teaching Assistant"
      session[:user].id
    else # for TA we need to get his instructor id and by default add it to his course for which he is the TA
      Ta.get_my_instructor(session[:user].id)
    end
  end

  def questionnaire_has_name?
    params[:questionnaire][:name].present?
  end

  def update_questionnaire_instructor

    # if quiz questionnaire assign instructor id
    # else assign ta id
    @questionnaire = Object.const_get(params[:questionnaire][:type]).new(questionnaire_params)

    # TODO: check for Quiz Questionnaire?
    if @questionnaire.type == "QuizQuestionnaire" # checking if it is a quiz questionnaire
      participant_id = params[:pid] # creating a local variable to send as parameter to submitted content if it is a quiz questionnaire
      @questionnaire.min_question_score = MINIMUM_QUESTION_SCORE
      @questionnaire.max_question_score = MAXIMUM_QUESTION_SCORE
      author_team = AssignmentTeam.team(Participant.find(participant_id))

      @questionnaire.instructor_id = author_team.id # for a team assignment, set the instructor id to the team_id

      #@successful_create = true
      save

      if(params[:new_question] || params[:new_choices])
        save_choices @questionnaire.id
      end
      #flash[:note] = "The quiz was successfully created." if @successful_create
      flash[:note] = "The quiz was successfully created."
      redirect_to controller: 'submitted_content', action: 'edit', id: participant_id
    else # if it is not a quiz questionnaire
      @questionnaire.instructor_id = Ta.get_my_instructor(session[:user].id) if session[:user].role.name == "Teaching Assistant"
      save

      redirect_to controller: 'tree_display', action: 'list'
    end
  end
end
