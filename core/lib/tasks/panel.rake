# SLA de demonstração do timeout do agente. As tasks publicam, por Routing::RulePublisher, uma nova
# versão da regra genérica ativa da marca, com outro then.sla_minutes; a mudança vale para as
# conversas roteadas depois dela.
#   bin/rails panel:demo_sla BRAND=<slug> MINUTES=<n>  SLA de n minutos
#   bin/rails panel:demo_sla_reset BRAND=<slug>        SLA da fila da regra genérica
module PanelDemoSla
  module_function

  def apply(slug, minutes)
    minutes = Integer(minutes.to_s, exception: false)
    raise ArgumentError, "MINUTES deve ser um inteiro maior que zero" unless minutes&.positive?

    publish(brand(slug)) { |_rule| minutes }
  end

  def reset(slug)
    publish(brand(slug)) do |rule|
      Routing::Queue.find_by!(name: rule["then"].fetch("queue")).sla_minutes
    end
  end

  def brand(slug)
    Brand.find_by(slug: slug.to_s) || raise(ArgumentError, "marca #{slug.inspect} não encontrada (BRAND)")
  end

  # Devolve a versão gravada, ou nil quando a regra já tem o SLA pedido.
  def publish(brand)
    rule = Tenancy.with_brand(brand) { RoutingRule.current.order(:position).find(&:generic?) }
    raise ArgumentError, "a marca #{brand.slug} não tem regra genérica ativa" if rule.nil?

    minutes = Tenancy.with_brand(brand) { yield rule }
    Routing::RulePublisher.update(
      brand: brand, rule_id: rule.rule_id, attributes: { then: rule["then"].merge("sla_minutes" => minutes) }
    )
  rescue Routing::RulePublisher::Unchanged
    nil
  end
end

namespace :panel do
  desc "Publica uma versão da regra genérica da marca com SLA de demonstração (BRAND, MINUTES)"
  task demo_sla: :environment do
    rule = PanelDemoSla.apply(ENV["BRAND"], ENV["MINUTES"])
    puts(rule ? "Regra #{rule.name} versão #{rule.version} com SLA de #{rule['then']['sla_minutes']} min" : "SLA já aplicado")
  end

  desc "Volta a regra genérica da marca ao SLA da fila dela (BRAND)"
  task demo_sla_reset: :environment do
    rule = PanelDemoSla.reset(ENV["BRAND"])
    puts(rule ? "Regra #{rule.name} versão #{rule.version} com SLA de #{rule['then']['sla_minutes']} min" : "SLA já é o da fila")
  end
end
