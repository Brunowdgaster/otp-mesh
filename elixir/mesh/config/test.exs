import Config

# Porta 0: o SO escolhe. Os testes descobrem a porta real com Mesh.Bridge.port/0.
#
# Porta fixa em teste é fonte de falha intermitente -- duas execuções
# simultâneas disputariam a mesma, e o sintoma seria "eaddrinuse" num teste que
# não tem nada a ver com rede.
config :mesh, bridge_port: 0
