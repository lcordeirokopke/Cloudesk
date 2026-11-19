# Painel do Mission Control - Jobs, montado em /jobs no web: filas, jobs agendados, fila de falhas,
# reprocessamento e descarte. O acesso é por HTTP basic auth, com as credenciais das variáveis de
# ambiente; sem elas, a gem recusa o acesso.
MissionControl::Jobs.http_basic_auth_user = ENV["MISSION_CONTROL_USER"]
MissionControl::Jobs.http_basic_auth_password = ENV["MISSION_CONTROL_PASSWORD"]
