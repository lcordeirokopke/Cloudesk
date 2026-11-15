# O Rails gera o db/structure.sql com pg_dump sem privilégios. Um banco novo é carregado a partir
# desse arquivo (db:migrate e db:prepare carregam o schema quando o banco não tem schema_migrations),
# e sem os GRANT o papel da aplicação ficaria sem acesso às tabelas.
# Esta extensão do db:schema:dump acrescenta ao arquivo os GRANT e REVOKE do banco, para que o banco
# carregado do schema tenha as mesmas permissões do banco migrado.
require "open3"

module StructurePrivileges
  module_function

  def append(db_config)
    return unless db_config.schema_format.to_sym == :sql

    path = ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(db_config)
    return unless path && File.exist?(path)

    File.open(path, "a") do |file|
      file.puts
      file.puts statements(db_config)
    end
  end

  def statements(db_config)
    config = db_config.configuration_hash
    env = {
      "PGHOST" => config[:host]&.to_s,
      "PGPORT" => config[:port]&.to_s,
      "PGUSER" => config[:username]&.to_s,
      "PGPASSWORD" => config[:password]&.to_s
    }.compact

    # -s: só o schema; -O: sem comandos de dono.
    output, status = Open3.capture2(env, "pg_dump", "-s", "-O", db_config.database)
    raise "pg_dump falhou ao extrair as permissões de #{db_config.database}" unless status.success?

    output.lines.grep(/\A(GRANT|REVOKE) /)
  end
end

Rake::Task["db:schema:dump"].enhance do
  ActiveRecord::Base.configurations.configs_for(env_name: ActiveRecord::Tasks::DatabaseTasks.env).each do |db_config|
    StructurePrivileges.append(db_config)
  end
end
