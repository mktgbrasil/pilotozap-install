# PilotoZap — Guia de Instalação

Seu robô de atendimento no WhatsApp, funcionando 24 horas por dia no seu próprio servidor.

Este guia foi escrito para quem **não é técnico**. Você não precisa saber programar,
não precisa de domínio e não precisa configurar nada de internet.

São **3 passos** e leva cerca de 15 minutos — a maior parte é só esperar.

---

## Antes de começar

Você vai precisar de duas coisas:

### 1. Um servidor (VPS)

É um computador na internet que fica ligado o tempo todo. Você aluga por mês
(custa em torno de R$ 30 a R$ 60).

| Item | Mínimo | Recomendado |
|---|---|---|
| Memória (RAM) | 2 GB | 4 GB |
| Disco | 20 GB | 40 GB |
| Sistema | Ubuntu 22.04 | Ubuntu 22.04 ou 24.04 |

> Na hora de criar o servidor, escolha **Ubuntu 22.04**.
> Você vai receber por e-mail um **endereço IP** (números tipo `191.20.30.40`)
> e uma **senha de root**. Guarde os dois — você vai usar os dois várias vezes.

### 2. O seu token

Um código comprido que você recebeu **na compra**, junto com o comando de instalação.
Ele é a sua chave para baixar o programa. Não compartilhe com ninguém.

Perdeu? Peça de novo a quem te vendeu o PilotoZap.

---

## Passo 1 — Entrar no servidor

No **Windows**, abra o **PowerShell** (tecla Windows, digite `PowerShell`, Enter).
No **Mac** ou **Linux**, abra o **Terminal**.

Digite, trocando pelo IP do seu servidor:

```
ssh root@191.20.30.40
```

Vai pedir a senha do servidor.
**Ao digitar a senha nada aparece na tela — isso é normal.** Digite e aperte Enter.

Se aparecer uma pergunta sobre "fingerprint", digite `yes` e Enter.

---

## Passo 2 — Rodar o instalador

Cole **o comando abaixo inteiro**, trocando `SEU_TOKEN` pelo token que você recebeu:

```
curl -fsSL https://raw.githubusercontent.com/mktgbrasil/pilotozap/main/install.sh | bash -s -- --token SEU_TOKEN
```

Aperte Enter e **espere**. Vai aparecer bastante texto na tela — isso é normal,
é o servidor montando o programa. Leva de 5 a 10 minutos.

> Se você usa o PowerShell, cole com o botão direito do mouse.
> Cuidado para não cortar nenhum pedaço do token.

Quando terminar, aparece:

```
  ╔══════════════════════════════════════════════════════════╗
  ║            PILOTOZAP INSTALADO COM SUCESSO!              ║
  ╚══════════════════════════════════════════════════════════╝
```

**Não feche essa janela ainda.** A tela mostra duas coisas importantes:
o **comando do túnel** e o **código da máquina**.

---

## Passo 3 — Abrir o painel pelo túnel SSH

Por segurança, o painel **não fica exposto na internet**. Ninguém consegue
achá-lo, nem sabendo o IP do seu servidor. Para abri-lo, você cria um "túnel"
do seu computador até o servidor.

Pense no túnel como um cabo invisível: enquanto ele estiver ligado, o painel
aparece no seu computador como se estivesse instalado nele.

### No Windows (PowerShell)

Abra uma **nova** janela do PowerShell (deixe a outra em paz) e cole:

```
ssh -L 3110:127.0.0.1:3110 root@191.20.30.40
```

### No Mac ou Linux (Terminal)

Abra uma **nova** aba do Terminal e cole exatamente o mesmo comando:

```
ssh -L 3110:127.0.0.1:3110 root@191.20.30.40
```

> Troque `191.20.30.40` pelo IP do **seu** servidor.
> O instalador já mostrou esse comando pronto, com o seu IP preenchido —
> é só copiar de lá.

Digite a senha do servidor. **Deixe essa janela ABERTA** enquanto usar o painel.
Se fechar, o painel para de abrir (o programa continua rodando no servidor,
só o "cabo" foi desconectado — basta abrir de novo).

### Agora abra o navegador em:

```
http://localhost:3110
```

Pronto: o painel do PilotoZap aparece.

---

## Passo 4 — Ativar a licença e criar seu login

### 1. Peça a licença

Na tela do instalador (e também dentro do painel) aparece um **código da máquina**,
um texto comprido tipo `604e58c3545226ef...`.

**Copie esse código e envie para quem te vendeu o PilotoZap.**
Você recebe de volta uma **chave de licença**, que você cola na tela de Licença
do painel.

Perdeu o código? Rode isto no servidor:

```
cat /opt/pilotozap/COMO-ACESSAR.txt
```

### 2. Crie o seu login e a sua senha

Logo depois de ativar a licença, o painel pede para você **escolher o seu
usuário e a sua senha**. Essa senha é sua — nem o vendedor tem acesso a ela.

> **Anote a senha em local seguro.** Use uma senha só sua, que você não use em
> outros sites.

### 3. Conecte o WhatsApp

No painel, vá em **Conexões** e leia o QR Code com o celular
(WhatsApp → Aparelhos conectados → Conectar aparelho).

> **Dica:** use um número de WhatsApp **separado** do seu pessoal.
> Um chip só para o atendimento automático.

---

## Se der errado

O instalador foi feito para não quebrar nada. Se ele parar no meio,
**pode rodar de novo sem medo** — ele continua de onde parou e não apaga nada:
seus dados, sua licença e a conexão do WhatsApp são preservados.

### Problemas mais comuns

| A mensagem diz... | O que fazer |
|---|---|
| "Faltou o token de acesso" | Você colou o comando sem a parte `--token SEU_TOKEN` no fim. Cole o comando completo. |
| "Seu token de acesso foi RECUSADO" | O token está errado ou expirou. Peça um token novo a quem te vendeu. |
| "Não encontrei o programa com este token" | O token não tem permissão. Confira se copiou ele inteiro; se sim, peça ao vendedor para liberar. |
| "O download veio inválido" | Quase sempre é o token. Peça um token novo. |
| "não confere com o original" | O download chegou pela metade. Rode o comando de novo — geralmente funciona na segunda. |
| "este servidor tem pouca memória" | Aumente o plano da VPS para 2 GB. É a solução mais barata e definitiva. |
| "precisa ser executado como administrador" | Digite `sudo -i`, aperte Enter, e rode o comando de instalação de novo. |
| "a porta 3110 já está sendo usada" | Acrescente `--porta 3111` no fim do comando e use `3111` também no túnel. |

### O túnel não conecta

- Confira se você está usando o **IP certo** e a **senha do servidor** (não a do painel).
- Se disser `Address already in use`, já existe outro túnel aberto na mesma porta.
  Feche as outras janelas do PowerShell/Terminal e tente de novo.
- Se disser `Connection refused`, o servidor pode estar desligado. Entre no painel
  do seu provedor de VPS e confira.

### O painel não abre (página em branco ou "não foi possível conectar")

1. Confirme que a janela do túnel continua aberta.
2. Confirme que o endereço é `http://localhost:3110` (com `http://`, não `https://`).
3. No servidor, rode e mande o resultado para o suporte:

```
cd /opt/pilotozap
docker compose ps
docker compose logs --tail 50
```

---

## Comandos do dia a dia

Todos rodam **dentro do servidor** (na janela do `ssh root@SEU_IP`).

| O que você quer | Comando |
|---|---|
| Ver se está no ar | `cd /opt/pilotozap && docker compose ps` |
| Ver o que está acontecendo | `cd /opt/pilotozap && docker compose logs --tail 50` |
| Reiniciar o programa | `cd /opt/pilotozap && docker compose restart` |
| Desligar | `cd /opt/pilotozap && docker compose stop` |
| Ligar de novo | `cd /opt/pilotozap && docker compose up -d` |
| Rever as instruções de acesso | `cat /opt/pilotozap/COMO-ACESSAR.txt` |

---

## Backup — seus dados estão seguros

O instalador já deixa o backup automático ligado. **Todo dia às 3h20 da manhã** ele salva:

- o banco de dados (conversas, contatos, agendamentos, licença);
- a sessão do WhatsApp (para não precisar ler o QR Code de novo).

Ficam guardados **7 backups diários** e **4 semanais**. Os mais antigos são apagados
sozinhos para não encher o disco.

| O que você quer | Comando |
|---|---|
| Fazer um backup agora | `bash /opt/pilotozap/backup.sh` |
| Ver os backups salvos | `bash /opt/pilotozap/backup.sh --listar` |
| Voltar para um backup | `bash /opt/pilotozap/backup.sh --restaurar CAMINHO_DO_ARQUIVO` |

Ao restaurar, o script **guarda antes os dados atuais**, então dá para voltar atrás
se você se arrepender. Ele pede uma confirmação digitada — não acontece sem querer.

> **Recomendação:** de tempos em tempos, baixe uma cópia dos backups para o seu
> computador. Se o servidor for perdido por completo, é isso que salva você.
> Rode no **seu computador** (não no servidor):
> ```
> scp -r root@191.20.30.40:/opt/pilotozap/backups ./backups-pilotozap
> ```

---

## Coisas que você NUNCA deve fazer

### 1. Nunca altere o arquivo `IDENTIDADE-NAO-ALTERAR.txt`

Sua licença está presa a uma "impressão digital" do servidor: o nome da máquina, o
endereço de rede e o usuário. Se qualquer um mudar, **a licença para de funcionar** e
você precisa pedir uma nova.

Pelo mesmo motivo, **não mexa** nestas linhas do arquivo `docker-compose.yml`:

```yaml
hostname: pilotozap-vps
mac_address: "02:42:ac:xx:xx:xx"
user: "root"
```

### 2. Nunca use `docker compose down -v`

O `-v` no final apaga **todos os dados**: conversas, contatos e a conexão do WhatsApp.
Para desligar com segurança, use sempre:

```
docker compose stop
```

### 3. Nunca troque `127.0.0.1` por `0.0.0.0` no `docker-compose.yml`

Isso publicaria o seu painel na internet aberta, sem proteção nenhuma.
O túnel SSH existe justamente para você não precisar disso.

---

## Atualizar para uma versão nova

Quando o vendedor avisar que saiu uma versão nova, rode **o mesmo comando de
instalação** de novo, com o mesmo token:

```
curl -fsSL https://raw.githubusercontent.com/mktgbrasil/pilotozap/main/install.sh | bash -s -- --token SEU_TOKEN
```

Seus dados, sua licença, seu login e a conexão do WhatsApp **são preservados**.
O instalador só troca o programa.

> Antes de atualizar, por segurança: `bash /opt/pilotozap/backup.sh`

---

## Remover o PilotoZap

```
bash /opt/pilotozap/uninstall.sh
```

Ele pede uma confirmação digitada, faz um último backup e guarda tudo em
`/var/backups/pilotozap`. **Seus backups nunca são apagados.**

---

## Perguntas frequentes

**Preciso deixar meu computador ligado?**
Não. O PilotoZap roda no servidor, que fica ligado 24 horas por dia. Seu computador
(e o túnel) só é necessário quando você quiser **olhar** o painel.

**Se eu fechar o túnel, o robô para de responder?**
Não. O robô continua atendendo normalmente. O túnel serve só para você ver o painel.

**Por que não posso simplesmente abrir pelo IP do servidor?**
Porque aí qualquer pessoa na internet também poderia. O túnel deixa o painel
visível só para quem tem a senha do seu servidor — é bem mais seguro e não custa nada.

**Meu celular precisa ficar com internet?**
Sim. O WhatsApp funciona por meio do seu celular, como no WhatsApp Web. Se o celular
ficar muito tempo sem internet, a conexão cai e você precisa ler o QR Code de novo.

**Posso usar meu número pessoal?**
Pode, mas não é recomendado. Use um chip separado só para o atendimento.

**Quantas mensagens posso disparar de uma vez?**
Vá com calma. Disparo em massa é a forma mais rápida de ter o número bloqueado pelo
WhatsApp. O sistema já vem com intervalos de 15 a 45 segundos entre mensagens — não
diminua esses valores. Espalhe os envios ao longo do dia.

**Esqueci a senha do painel. E agora?**
A senha é criada por você e não fica guardada em lugar nenhum do servidor.
Peça ao vendedor o procedimento para redefinir o acesso.

**Onde ficam meus dados?**
Tudo dentro do seu servidor, na pasta `/opt/pilotozap/dados`. Nada é enviado para
fora, exceto as mensagens que a inteligência artificial precisa processar.

---

## Precisa de ajuda?

Ao acionar o suporte, mande sempre estas três informações — assim a resposta vem
muito mais rápido:

1. o que você estava tentando fazer;
2. a mensagem de erro (foto da tela ou texto copiado);
3. o resultado deste comando, rodado no servidor:

```
cd /opt/pilotozap && docker compose ps && docker compose logs --tail 30
```

> **Nunca envie o seu token** em prints ou mensagens públicas. Ele é a sua chave de compra.
