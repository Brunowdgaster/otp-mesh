import Config

# Porta da ponte entre o gateway em Go e o núcleo.
#
#   nil -> a ponte não sobe
#   0   -> o sistema operacional escolhe uma porta livre
#   N   -> porta fixa
#
# A porta ser configurável é o que permite a MESMA árvore de supervisão rodar
# em teste, em CI e em uso. Um listener que insiste numa porta fixa quebra o CI
# quando ela está ocupada, e quebra teste que roda em paralelo.
inteiro = fn var, padrao ->
  case System.get_env(var) do
    nil -> padrao
    "" -> padrao
    v -> String.to_integer(v)
  end
end

# As duas vem do ambiente para que o MESMO build sirva a teste, CI, benchmark e
# uso -- sem recompilar e sem editar arquivo.
config :mesh, bridge_port: inteiro.("MESH_BRIDGE_PORT", 4040)

# Telemetria periodica: desligada por padrao. Ver Mesh.Reporter.
config :mesh, report_interval_ms: inteiro.("MESH_REPORT_MS", nil)

import_config "#{config_env()}.exs"
