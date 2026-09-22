# Manual — Criar um novo usuário no LabSC (CA307)

**Para quem é:** administradores do FreeIPA do LabSC (grupo `admins`), cada um com a **sua
própria conta**. Ninguém usa a conta compartilhada `admin`: ela é só para emergência e fica no
KeePass.

**O que você tem no final:** um usuário com login e senha temporária, e um home NFS já criado
com cota, que monta sozinho em `/home/<login>` nas máquinas da CA307.

---

## 0. Caminho

```
sua máquina --[SSH]--> VM cd108 (cd108.tutu.eng.br / 103.0.1.43)
                           ├─ FreeIPA (ipa1/ipa2): cria a conta, com o SEU ticket Kerberos
                           └─ sigivestserver (192.168.122.1): cria o home ZFS + cota
```

A VM cd108 é o host administrativo do LabSC, equivalente ao `ops` do LABIC.

## 1. Pré-requisitos

- Sua conta no FreeIPA do LabSC, membro do grupo `admins`. Quem cria ela para você é outro
  admin, com o mesmo script e `--groups admins`.
- Estar na rede do campus (`103.0.0.0/19`) ou na VPN.

## 2. Entrar na VM cd108 e tirar o ticket

```sh
ssh <seu-usuario>@cd108.tutu.eng.br
kinit <seu-usuario>
klist          # "Default principal: <seu-usuario>@LABSCIPA.TUTU.ENG.BR"
```

## 3. Rodar o script

```sh
cd ~/cd108_ansible        # ou onde estiver o clone do repositório na VM
./scripts/commission-user.sh
```

Ou com tudo na linha de comando:

```sh
./scripts/commission-user.sh \
  --user jsilva --first João --last Silva \
  --groups students --quota 10G \
  --ra 1234567 --email jsilva@alunos.utfpr.edu.br
```

| Flag | Obrigatório? | O que é |
|---|---|---|
| `--user` | sim | login: minúsculas, sem espaço (o script valida) |
| `--first` / `--last` | sim | nome e sobrenome |
| `--groups` | não (padrão `students`) | grupo(s) IPA, separados por vírgula |
| `--quota` | não (padrão `10G`) | cota do home |
| `--ra`, `--email`, `--phone` | não | ficam na ficha IPA |
| `--yes` | não | não pede confirmação |

O script faz, nesta ordem:

1. **Confere** que a VM está no realm `LABSCIPA` e que o ticket é seu. Isso impede criar, por
   engano, um usuário no realm do LABIC.
2. **FreeIPA:** cria o usuário com **senha aleatória** e o coloca nos grupos pedidos.
   A senha temporária aparece **uma única vez** na tela: **anote na hora**.
3. **uid:** resolve o uid que o IPA atribuiu e confere que ele está na faixa do LabSC
   (500600000–500799999).
4. **Home:** cria `hdmirror/remotehomes/<login>` no sigivestserver com a cota, copia o
   `/etc/skel`, ajusta o dono e aplica permissão `700`. O script confere que o `/etc/exports` do
   servidor não mudou (ele tem exports feitos à mão que não são nossos).

Pode rodar de novo à vontade: se o usuário ou o home já existem, o script não recria nada e só
reaplica a cota.

## 4. Verificar

```sh
ipa user-show <login>
getent passwd <login>
ipa hbactest --user=<login> --host=<máquina-da-ca307>.labscipa.tutu.eng.br --service=sshd
#   → "Access granted: True"
```

Se der `False`: a máquina não está no grupo `public-workstations` ou o usuário não está em
`students`. Veja [`../identity/login-debugging.md`](../identity/login-debugging.md) §4.

## 5. O que mandar para o usuário

Mande o login por um canal e a senha por outro (por exemplo: e-mail com o login, pessoalmente
ou WhatsApp com a senha).

```
Login: <login>   (nas máquinas da CA307)
Senha temporária: <a que o script imprimiu>
No primeiro login o sistema pede uma senha nova. Troque com calma: a política só
permite UMA troca por hora.
```

## 6. Problemas comuns

| Sintoma | Causa | O que fazer |
|---|---|---|
| `no 'ipa' CLI` / `enrolled in 'nothing'` | você não está na VM cd108, ou ela ainda não foi inscrita no IPA | rode na VM cd108; inscrição: `docs/identity/runbook.md` §1 |
| `could not resolve uid` | o SSSD ainda não propagou | espere 30 s e rode de novo (ele pula o que já foi feito) |
| `uid ... outside labsc's IPA range` | existe um usuário **local** com o mesmo nome na VM | não continue; avise outro admin |
| pede senha de `moritz@192.168.122.1` | a chave `labsc-mkhome` ainda não foi instalada | use sua conta com sudo no sigivestserver (`NFS_SSH=<você>@192.168.122.1`) ou peça a um admin; `runbook.md` §3 |
| `/etc/exports CHANGED` | alguém alterou os exports durante a execução | **pare** e investigue antes de qualquer outra coisa |
| o usuário esqueceu a senha | — | `ipa user-mod <login> --random` e entregue a nova senha |
| o usuário não consegue entrar | vários motivos | [`../identity/login-debugging.md`](../identity/login-debugging.md) |
