# DungeonBox — infraestrutura

Manifestos Kubernetes do DungeonBox. A aplicação vive em
[DungeonBox-App](https://github.com/analaura-gb/DungeonBox-App), que publica as
imagens no GHCR; este repositório só descreve como elas rodam.

O cluster é k3s sobre hardware doméstico: um notebook como control-plane e 20 TV
Box ARM como agentes.

## O cluster

O control-plane é o `tvbox-master`, o notebook. Ele **não** recebe label nenhum,
e isso é deliberado: como todo workload tem `nodeSelector`, nada é agendado nele.
O control-plane fica livre.

As 20 caixas recebem `layer` e, quando o grupo precisa distinguir serviço,
`module`:

| nós | layer | module | o que roda |
|---|---|---|---|
| tvbox-01 | `assets` | — | nginx servindo a arte |
| tvbox-02 a 05 | `frontend` | auth, store, ranking, game | 1 réplica cada |
| tvbox-06 a 08 | `backend` | auth | 3 réplicas |
| tvbox-09 a 12 | `backend` | store | 4 réplicas |
| tvbox-13 a 15 | `backend` | ranking | 3 réplicas |
| tvbox-16 a 19 | `backend` | game | 4 réplicas |
| tvbox-20 | `database` | — | Postgres |

Cada grupo de backend tem exatamente tantos nós quanto réplicas, e a
`podAntiAffinity` é obrigatória. Isso significa que um nó `NotReady` deixa um pod
`Pending` até ele voltar — não há folga para realocar. É consequência aceita de
ter 20 caixas para 20 vagas, e é por isso que os backends usam
`maxUnavailable: 1` com `maxSurge: 0`: durante uma atualização, o pod novo só
nasce depois que o antigo sai, porque não existe nó sobrando para os dois.

Os frontends fazem o inverso, `maxSurge: 1` com `maxUnavailable: 0`, porque não
têm anti-afinidade — o pod novo pode dividir a caixa com o antigo, e a
atualização sai sem queda.

## Antes de aplicar

**Os labels.** Sem eles nada é agendado, e o sintoma é silencioso: todos os pods
ficam `Pending` sem mensagem de erro. A causa só aparece no `kubectl describe`,
como `node(s) didn't match Pod's node affinity/selector`.

```bash
kubectl label node tvbox-01 layer=assets --overwrite
kubectl label node tvbox-02 layer=frontend module=auth --overwrite
kubectl label node tvbox-03 layer=frontend module=store --overwrite
kubectl label node tvbox-04 layer=frontend module=ranking --overwrite
kubectl label node tvbox-05 layer=frontend module=game --overwrite
kubectl label node tvbox-06 tvbox-07 tvbox-08 layer=backend module=auth --overwrite
kubectl label node tvbox-09 tvbox-10 tvbox-11 tvbox-12 layer=backend module=store --overwrite
kubectl label node tvbox-13 tvbox-14 tvbox-15 layer=backend module=ranking --overwrite
kubectl label node tvbox-16 tvbox-17 tvbox-18 tvbox-19 layer=backend module=game --overwrite
kubectl label node tvbox-20 layer=database --overwrite
```

```bash
kubectl get nodes -L layer,module
```

O `--overwrite` é necessário para corrigir um label existente: sem ele, o
`kubectl label` falha quando a chave já tem outro valor.

Os labels vivem no datastore do control-plane, não nas caixas. Se o cluster for
reconstruído, os Node objects nascem de novo e os labels se perdem — rotule
outra vez.

O control-plane não entra nessa lista de propósito: sem `layer` nem `module`,
nenhum workload é agendado nele.

**As imagens do migrator.** Pacote novo no GHCR nasce privado, e o k3s não tem
credencial. As quatro `dungeonbox-*-migrator` precisam ser públicas, senão os
Jobs de migração ficam em `ImagePullBackOff`.

**As tags.** São 12 ocorrências de `REPLACE_WITH_SHA`:

- 8 no bloco `images:` do `kustomization.yaml`, uma por imagem da aplicação
- 4 nos `migration-job.yaml`, que ficam fora do kustomize

O placeholder é intencional. Se alguém aplicar um Deployment com `kubectl apply
-f` em vez de `-k`, a tag inválida falha no pull em vez de rodar silenciosamente
um build antigo.

**Os Secrets.** Seis, criados a partir dos `.example.yaml` irmãos. O
`.gitignore` bloqueia qualquer `*secret*.yaml` que não seja `.example`, então o
arquivo real fica só na máquina.

| Secret | origem |
|---|---|
| `postgres-secrets` | `kubernetes/postgres/secret.example.yaml` |
| `dungeonbox-jwt` | `kubernetes/backend/jwt-secret.example.yaml` |
| `auth-backend-secrets` | `kubernetes/backend/auth/secret.example.yaml` |
| `store-backend-secrets` | `kubernetes/backend/store/secret.example.yaml` |
| `ranking-backend-secrets` | `kubernetes/backend/ranking/secret.example.yaml` |
| `game-backend-secrets` | `kubernetes/backend/game/secret.example.yaml` |

O `dungeonbox-jwt` é um Secret único compartilhado pelos quatro backends, em vez
de quatro cópias. O auth assina o token e os outros três validam: cópias que
divergissem causariam três serviços concordando e um rejeitando todo login.

Falta um sétimo Secret, o `dungeonbox-tls`, que não tem exemplo porque não é
criado à mão — veja a seção de TLS.

## Instalação inicial

Só na primeira vez, ou depois de reconstruir o cluster. As dependências não são
todas resolvidas pelo Kubernetes, então a ordem importa:

```bash
# os labels dos 20 nós
kubectl create namespace dungeonbox
# os 6 Secrets
kubectl apply -k kubernetes
# esperar o Postgres ficar Ready
kubectl apply -f kubernetes/backend/auth/migration-job.yaml
kubectl apply -f kubernetes/backend/store/migration-job.yaml
kubectl apply -f kubernetes/backend/ranking/migration-job.yaml
kubectl apply -f kubernetes/backend/game/migration-job.yaml
```

O namespace é criado por comando, não por manifesto. Ele é pré-requisito de todo
o resto: os 28 recursos declaram `namespace: dungeonbox` e os Secrets precisam
dele existindo antes de serem criados. Como é criado uma vez e nunca muda, um
arquivo só repetiria o que o comando já diz. Em troca, ele fica sendo o único
objeto sem o label `app.kubernetes.io/part-of` — o que não custa nada, porque
nada seleciona por ele.

O `apply -k` é o kustomization — o `-k` manda o kubectl ler o
`kustomization.yaml` do diretório. É ele que aplica os 28 recursos de uma vez,
com as tags do bloco `images:` já substituídas.

Os backends ficam `Ready` mesmo sem as migrações, porque a readiness probe
(`/api/health/ready`) só faz `SELECT 1` — ela verifica a conexão, não o schema.
Então eles entram em rotação e dão erro 500 nas consultas reais até os Jobs
rodarem. Rodar as migrações antes de expor o Ingress evita isso.

### O que fica fora do kustomize

- **o namespace**, que é pré-requisito e vem por comando
- **os 6 Secrets**, porque o valor real não é versionado
- **os 4 `migration-job.yaml`**, porque precisam rodar depois do banco e antes
  do tráfego, não junto com o resto
- **os `.example.yaml`**, que são molde e não recurso

## Deploy rotineiro

Depois da instalação, o ciclo normal é bem mais curto. O que repete é só isto:

1. **Atualizar a tag** da imagem no bloco `images:` do `kustomization.yaml`. É
   um arquivo só, para as 8 imagens da aplicação.
2. **Rodar a migração**, se o serviço ganhou migração nova. Antes do passo 3,
   para o schema estar pronto quando o código novo subir.
3. **`kubectl apply -k kubernetes`**, que faz o rollout.

```bash
kubectl delete job auth-migrate -n dungeonbox --ignore-not-found
kubectl apply -f kubernetes/backend/auth/migration-job.yaml
kubectl wait --for=condition=complete job/auth-migrate -n dungeonbox --timeout=5m
kubectl apply -k kubernetes
```

O `delete` antes do `apply` não é zelo: **Job é imutável**. O
`spec.template` não pode ser alterado depois de criado, então reaplicar o mesmo
nome com uma tag diferente falha com `field is immutable`. O
`ttlSecondsAfterFinished: 300` apaga o Job cinco minutos depois de terminar, mas
dentro dessa janela o `delete` é necessário.

A tag dos `migration-job.yaml` é editada arquivo por arquivo, porque eles ficam
fora do kustomize e não são alcançados pelo bloco `images:`.

Quando só a arte muda, nada disso é preciso: a cópia para o volume não passa por
deploy nenhum. Veja a seção da arte.

### Resumo do que repete

| passo | quando |
|---|---|
| rotular os nós | instalação, e se o cluster for reconstruído |
| `kubectl create namespace` | instalação |
| os 6 Secrets | instalação, e quando um valor mudar |
| `apply -k kubernetes` | todo deploy |
| `migration-job.yaml` | quando houver migração nova |
| copiar arte para o volume | quando a arte mudar, sem deploy |
| nada, para o TLS | a renovação é automática pelo cron do notebook |

## TLS

O `ingress.yaml` referencia o Secret `dungeonbox-tls`, e **não existe manifesto
que o crie**. Isso é esperado.

O certificado é emitido pelo [lego](https://go-acme.github.io/lego/) rodando no
`tvbox-master`, com desafio `dns01` pelo DuckDNS. A escolha do DNS-01 em vez do
HTTP-01 é o que permite servir só HTTPS: a validação é uma consulta DNS que sai
da rede, então nenhuma porta de entrada é necessária para emitir ou renovar.

O lego guarda os arquivos em `/etc/lego/certificates/` e, a cada emissão ou
renovação bem-sucedida, chama `/usr/local/bin/lego-deploy-secret`, que reescreve
o Secret no cluster. O hook existe como arquivo porque ele encadeia dois comandos
com pipe, e o lego executa hooks sem shell — um pipe na linha do
`--deploy-hook` chegaria como argumento literal.

A renovação está no crontab do root do notebook, diária. O lego decide sozinho
quando renovar, por volta de um terço da validade restante, e sai sem fazer nada
nos outros dias.

O token do DuckDNS fica em `/etc/lego/duckdns-token`, modo 600 do root, e serve
tanto ao lego quanto à atualização de IP do DDNS — um arquivo só, para não haver
duas cópias a girar.

## Rede

Só a **443** é encaminhada no roteador para o notebook. A 80 não é necessária,
porque a validação do certificado não usa entrada. A consequência é que quem
digitar o endereço sem `https://` recebe erro de conexão, não um
redirecionamento.

O `klipper-lb` do k3s publica o Traefik prendendo as portas nos nós, então
qualquer nó serve como ponto de entrada; o encaminhamento aponta para o notebook
por ele ter IP reservado no DHCP.

### Rotas

Host: `dungeon-box.duckdns.org`

| caminho | destino |
|---|---|
| `/api/auth` | auth-backend:3000 |
| `/api/store` | store-backend:3001 |
| `/api/ranking` | ranking-backend:3002 |
| `/api/game` | game-backend:3003 |
| `/auth/` | auth-frontend:8080 |
| `/store/` | store-frontend:8080 |
| `/ranking/` | ranking-frontend:8080 |
| `/game/` | game-frontend:8080 |
| `/assets/` | assets-static:8080 |
| `/` | auth-frontend:8080, mas o Middleware redireciona para `/auth/` antes |

Dois Middlewares do Traefik cuidam dos redirecionamentos: a raiz vai para
`/auth/`, e `/auth` sem barra final vai para `/auth/`. O segundo existe porque o
nginx dos frontends só conhece `location /auth/` — sem ele, o caminho sem barra
cai no `return 404`.

Os dois são agnósticos de host, capturando `([^/]+)`, então trocar de domínio não
exige mexer neles.

### Trocar de domínio

O hostname aparece em duas linhas, as duas no `ingress.yaml`. Nenhuma imagem
precisa ser reconstruída: as variáveis `VITE_*` do repositório da aplicação são
caminhos relativos (`/api`, `/auth/`), nunca URLs absolutas, então o domínio não
entra no bundle.

## Armazenamento

Dois volumes, os dois pelo `local-path` do k3s, que é um diretório num nó
específico com acesso `ReadWriteOnce`:

- **Postgres**, 5Gi, na tvbox-20. Uma instância com quatro databases —
  `auth_db`, `store_db`, `ranking_db`, `game_db` — criados pelo
  `initdb-configmap.yaml`, que a imagem do Postgres executa uma única vez,
  quando o diretório de dados está vazio.
- **Assets**, 2Gi, na tvbox-01.

Como o `local-path` prende o volume ao nó, os dois workloads são de 1 réplica e
presos por `nodeSelector`. Se a caixa morrer, o pod não migra: os dados estão
nela, e nenhum dos dois volumes tem cópia em outro lugar. Os dois pedem backup —
o banco por conter as compras e o ranking, e os assets porque a arte é enviada
direto para o volume, sem passar por repositório.

### A arte

O `assets-static` é a imagem oficial do nginx sem modificação: a configuração vem
de ConfigMap e o conteúdo do volume. Nenhuma imagem é construída, e é esse o
ponto — adicionar personagem ou trocar sprite não reconstrói a aplicação.

Os caminhos ficam gravados no banco, em `image_url`, como caminhos relativos
(`/assets/catalog/iron-will.png`). Então quem serve `/assets/` pode mudar sem
tocar no banco nem no frontend.

A arte é enviada direto para o volume, por cópia. O caminho mais curto, do
notebook, dispensa saber onde o `local-path` guardou o diretório:

```bash
kubectl cp arte.png -n dungeonbox <pod>:/data/assets/catalog/arte.png
```

O nginx roda como uid 101 e monta o volume somente leitura, então o arquivo
precisa estar legível por todos — um arquivo copiado como root sem permissão de
leitura vira 403, não 404, e o sintoma não aponta para a causa.

Como não há cópia em repositório, **o volume é a fonte da verdade da arte**. É o
que o torna o segundo ponto a precisar de backup.

O cache é curto, com ETag e revalidação, e não `immutable` como nos frontends. Os
nomes dos arquivos não têm hash, então um cache longo esconderia a troca de uma
arte pelo mesmo nome.

## Se você pegou este repositório

Os manifestos descrevem 20 TV Box ARM e um notebook, com cada serviço preso a um
grupo de nós por `nodeSelector`. Em outro hardware, o que precisa mudar é:

- **os labels**, que são a tradução do seu inventário de máquinas
- **as `replicas`**, que hoje são exatamente o número de nós de cada grupo,
  porque a `podAntiAffinity` é obrigatória e não há folga
- **o `nodeSelector`** dos dois volumes, se os nós de banco e de arte forem
  outros
- **o `host`** do `ingress.yaml`, em duas linhas
- **o `storageClassName`**, se o cluster não usar `local-path`

Com um nó só, o caminho mais curto é tirar o `nodeSelector` e a
`podAntiAffinity` de todos os workloads e baixar as `replicas` para 1 — aí nada
depende da topologia.
