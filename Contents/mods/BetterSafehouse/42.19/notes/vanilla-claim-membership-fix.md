# Fix: reivindicação vanilla bloqueada errado pra quem é só membro/sub-dono

Status: **planejado, não implementado ainda**.

## Problema relatado

Com `Convites aprimorados` (`EnhancedInvites`) ligado, se um jogador já é **membro** (convidado) ou **sub-dono** de uma safehouse de outra pessoa, e tenta reivindicar uma safehouse própria usando o botão vanilla **"Reivindicar Base"**, o jogo bloqueia — mesmo o jogador não sendo dono de nada.

## Causa raiz (confirmada lendo o código vanilla do jogo)

`ISWorldObjectContextMenu.onTakeSafeHouse` (vanilla, `media/lua/client/ISUI/ISWorldObjectContextMenu.lua:517` do jogo) só faz:

```lua
ISWorldObjectContextMenu.onTakeSafeHouse = function(worldobjects, square, player)
    local playerObj = getSpecificPlayer(player)
    sendSafehouseClaim(square, playerObj, playerObj:getUsername())
end
```

`sendSafehouseClaim` é uma função **nativa (Java)**, sem definição em nenhum arquivo Lua do jogo — não existe gancho Lua pra interceptar ou alterar a checagem de "já tem/participa de uma safehouse" que roda dentro dela. Essa checagem nativa aparentemente trata **qualquer membro** (não só donos) como "já tem uma safehouse", e nenhum mod Lua consegue mudar isso diretamente.

Confirmado também: hoje (`BetterSafehouse_B42.lua`, `BS_getClaimBlockReason`) o mod só bloqueia visualmente o botão por causa de **área mínima/máxima** e **cooldown** — nunca por posse/participação em outra safehouse. Ou seja, hoje o botão aparece **sempre clicável**, e a rejeição por posse acontece silenciosamente, depois do clique, direto no engine.

O caminho **CustomClaim** (Claim Personalizado, próprio do mod) já faz a checagem certa hoje: com `EnhancedInvites` ligado, ele só olha se o jogador é **dono** de alguma safehouse (`userOwnsAnySafehouse`, `BetterSafehouse_CustomClaim_Server.lua`), ignorando participação como membro — então esse caminho já funciona corretamente. O bug é exclusivo do caminho **vanilla**.

## Sub-dono também é afetado (confirmado)

Sub-dono não existe pro vanilla — é só uma camada de permissão extra controlada numa tabela separada do próprio mod (`02_BetterSafehouse_SubOwner_Shared.lua`, indexada por safehouse). Pro `SafeHouse` nativo, um sub-dono é só mais um membro comum na lista de jogadores. A checagem nativa trata os dois (membro comum e sub-dono) exatamente igual — então a mesma correção cobre os dois automaticamente, sem tratamento especial.

## Solução (não dá pra "consertar" a checagem nativa — precisa desviar dela)

Quando `EnhancedInvites` estiver ligado **e** o jogador for membro/sub-dono (mas não dono) de qualquer safehouse, em vez de deixar seguir pro `_vanilla`/`sendSafehouseClaim` (que rejeita errado), interceptar **antes** e criar a safehouse por conta própria, chamando `SafeHouse.addSafeHouse(x, y, w, h, username)` diretamente — a mesma API que o `CustomClaim` já usa e que não tem a checagem de "já é membro" bugada.

Pra qualquer jogador fora desse cenário específico (não é membro de nada, ou `EnhancedInvites` desligado), nada muda — o `_vanilla` normal continua rodando exatamente como hoje.

### Peças necessárias

| Peça | Já existe no mod? |
|---|---|
| Criar a safehouse direto (`SafeHouse.addSafeHouse`) | ✅ sim, usado pelo CustomClaim (`createSafehouse`, `BetterSafehouse_CustomClaim_Server.lua`) |
| Checar "é dono de alguma?" (ignorando membro) | ✅ sim (`userOwnsAnySafehouse`) |
| Validações de segurança (área carregada, zona de guerra, outro jogador na área, sobreposição) | ✅ sim, no CustomClaim — só reaproveitar |
| Cooldown / anti-spam | ✅ sim |
| Tamanho do prédio clicado (W×H) | ✅ sim (`BS_getBuildingAreaFromSquare`, `BetterSafehouse_B42.lua:2459`) |
| Origem X/Y do prédio clicado | ⚠️ parcial — a função só devolve W/H hoje; falta expor X/Y (provavelmente `def:getX()`/`def:getY()`, mesma fonte de dados) |
| Comando de rede novo (client → server) pra esse caminho específico | ❌ precisa criar |
| Gancho no client pra decidir "desvia ou deixa vanilla seguir" | ❌ precisa criar |

**Estimativa**: ~150–250 linhas, em 2–3 arquivos (`BetterSafehouse_B42.lua` client, um novo handler server-side, talvez estender `BetterSafehouse_Server.lua` ou criar um arquivo dedicado). Risco baixo — caminho novo e isolado, só ativa na combinação específica (Convites aprimorados ligado + jogador é membro/sub-dono de outra + clicou em "Reivindicar Base").

## Melhoria de UI incluída no mesmo pacote

Hoje o botão "Reivindicar Base" nunca fica vermelho/bloqueado por posse (só por área/cooldown). Vamos aproveitar a mesma checagem "é dono de alguma?" pra deixar o botão refletir o estado certo *antes* do clique:

- **Já é dono de uma safehouse** → botão bloqueado/vermelho, tooltip "Você já possui uma safehouse." (aviso novo, não existe hoje).
- **Não tem safehouse nenhuma** → botão disponível, normal.
- **É só membro ou sub-dono de outra, com Convites aprimorados ligado** → botão disponível (era o caso bugado).
- **É só membro/sub-dono, com Convites aprimorados desligado** → continua bloqueado (mantém a regra rígida que o CustomClaim já aplica nesse cenário).

## Arquivos prováveis a mexer na implementação

- `media/lua/client/BetterSafehouse/BetterSafehouse_B42.lua` — `BS_getClaimBlockReason` (novo check de posse pro botão), `BS_patchOnTakeSafeHouse` (desvio do claim), `BS_getBuildingAreaFromSquare` (expor X/Y).
- Novo arquivo server-side (ou extensão de `BetterSafehouse_Server.lua`) — handler do novo comando de claim-desvio, reaproveitando validações do `BetterSafehouse_CustomClaim_Server.lua`.
- Traduções EN/PTBR — nova mensagem de bloqueio ("Você já possui uma safehouse", já existe como `IGUI_BetterSafehouse_Claim_AlreadyHasSafehouse`, reaproveitável) e qualquer texto novo de resultado do claim desviado.
