module Admin
  # Regras de roteamento da marca, gravadas só pelo Routing::RulePublisher:
  #   index:      maior versão de cada regra, ativa ou não, em ordem de avaliação (position, rule_id);
  #   show:       versão vigente, todas as versões e o diff de cada uma;
  #   new/create: regra nova pelo formulário estruturado (Admin::RuleForm);
  #   edit/update: nova versão, com a versão lida (expected_version);
  #   activate/deactivate: nova versão com active true ou false, com a versão lida.
  # Recusas do RulePublisher (definição inválida, sem regra genérica, sem mudança, versão
  # desatualizada) voltam ao formulário com status 422 ou à tela da regra com a mensagem.
  class RulesController < BaseController
    ERRORS = [
      Routing::RuleDefinition::Invalid, Routing::RulePublisher::Error, ActiveRecord::RecordInvalid
    ].freeze

    def index
      in_brand do
        @rules = RoutingRule.latest_versions.order(:position, :rule_id).to_a
        @queue_names = Routing::Queue.pluck(:name)
      end
    end

    def show
      in_brand do
        @rule = RoutingRule.latest_versions.find_by!(rule_id: params[:rule_id])
        @versions = RoutingRule.where(rule_id: @rule.rule_id).order(version: :desc).to_a
        @history = Admin::History.for_rule(@rule.rule_id)
      end
    end

    def new
      @form = Admin::RuleForm.from_rule(brand: current_brand)
      in_brand { load_options }
    end

    def create
      @form = Admin::RuleForm.from_params(brand: current_brand, params: params.fetch(:rule, {}))
      rule = Routing::RulePublisher.create(brand: current_brand, attributes: @form.to_attributes, operator_name: operator_name)
      redirect_to admin_rule_path(rule.rule_id), notice: "Regra criada", status: :see_other
    rescue *ERRORS => error
      in_brand { load_options }
      render_error(:new, error)
    end

    def edit
      in_brand do
        @rule = RoutingRule.latest_versions.find_by!(rule_id: params[:rule_id])
        load_options
      end
      @form = Admin::RuleForm.from_rule(brand: current_brand, rule: @rule)
      @expected_version = @rule.version
    end

    def update
      in_brand { @rule = RoutingRule.where(rule_id: params[:rule_id]).order(version: :desc).first! }
      @form = Admin::RuleForm.from_params(brand: current_brand, params: params.fetch(:rule, {}), rule: @rule)
      Routing::RulePublisher.update(
        brand: current_brand, rule_id: @rule.rule_id, attributes: @form.to_attributes,
        expected_version: params[:expected_version], operator_name: operator_name
      )
      redirect_to admin_rule_path(@rule.rule_id), notice: "Nova versão publicada", status: :see_other
    rescue *ERRORS => error
      in_brand { load_options }
      @expected_version = params[:expected_version]
      render_error(:edit, error)
    end

    def activate
      change_state(:activate, "Regra ativada")
    end

    def deactivate
      change_state(:deactivate, "Regra desativada")
    end

    private

    def change_state(operation, notice)
      in_brand { RoutingRule.where(rule_id: params[:rule_id]).first! }
      Routing::RulePublisher.public_send(
        operation, brand: current_brand, rule_id: params[:rule_id], expected_version: params[:expected_version],
                   operator_name: operator_name
      )
      redirect_to admin_rule_path(params[:rule_id]), notice: notice, status: :see_other
    rescue *ERRORS => error
      redirect_to admin_rule_path(params[:rule_id]), alert: message_for(error), status: :see_other
    end

    def load_options
      @queues = Routing::Queue.order(:name).to_a
    end

    def render_error(template, error)
      @errors = [ message_for(error) ]
      render template, status: :unprocessable_content
    end

    def message_for(error)
      case error
      when Routing::RulePublisher::Stale then "A regra mudou depois de lida; recarregue a página. (#{error.message})"
      when Routing::RulePublisher::Unchanged then "A edição não muda a regra."
      when Routing::RulePublisher::NoGenericRule then "A marca precisa manter uma regra genérica ativa: #{error.message}."
      when ActiveRecord::RecordInvalid then error.record.errors.full_messages.join("; ")
      else error.message
      end
    end
  end
end
