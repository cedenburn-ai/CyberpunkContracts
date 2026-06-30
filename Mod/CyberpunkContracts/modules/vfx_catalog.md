# Cyberpunk Contracts — VFX / Status-FX Catalog

Dumped live from this build's TweakDB (`CC: Dump VFX names`, 114 effects). The left token is the **VFX name** (for the raw `StartEffectEvent` path); the right is the **source record** it was pulled from. Strip the trailing `_inlineN` and the parent is usually an applicable `BaseStatusEffect.*` record you can feed to `ApplyStatusEffect`.

Two ways to fire these (see the test hotkeys):

- **Status effect (reliable):** `Game.GetStatusEffectSystem():ApplyStatusEffect(id, "BaseStatusEffect.X")` — plays the VFX *and* the gameplay.

- **Raw VFX (experimental):** `GameObjectEffectHelper.StartEffectEvent(entity, CName.new("vfx_name"))` — visual only.


---


## ★ Best for play_fx / explode

- `empExplosionDestruction`  ←  `Effectors.Android_ExplodeOnElectricDeathEffectorVFX`
- `w_expl_blackwall_shortcircuit`  ←  `BaseStatusEffect.CyberwareMalfunctionBlackwall_inline1`
- `w_expl_blackwall_npc_death_gameplay`  ←  `BaseStatusEffect.HauntedGunBlackWallForceKill_inline2`
- `mask_explode`  ←  `Oda.OverHeatVFX_inline2`
- `status_burning`  ←  `AIQuickHackStatusEffect.HackOverheatBase_inline2`
- `igni`  ←  `NewPerks.Tech_Right_Milestone_3_inline38`
- `status_electrocuted`  ←  `Ability.HasHealthMonitorBomb_inline7`
- `status_emp`  ←  `BaseStatusEffect.BaseEMP_inline3`
- `status_smoke_bomb`  ←  `BaseStatusEffect.SmokeBomb_inline3`
- `status_sandstorm`  ←  `BaseStatusEffect.SandstormAbstract_inline0`
- `status_knockdown`  ←  `BaseStatusEffect.Knockdown_inline4`
- `status_stunned`  ←  `BaseStatusEffect.Stun_inline3`

---


## Explosions & Fire  (10)

- `empExplosionDestruction`  ←  `Effectors.Android_ExplodeOnElectricDeathEffectorVFX`
- `hacks_overheat_lvl1`  ←  `BaseStatusEffect.OverheatLevel1_inline6`
- `hacks_overheat_lvl2`  ←  `BaseStatusEffect.BaseOverheat_inline6`
- `igni`  ←  `NewPerks.Tech_Right_Milestone_3_inline38`
- `mask_explode`  ←  `Oda.OverHeatVFX_inline2`
- `quickhack_overheat`  ←  `BaseStatusEffect.BaseOverheat_inline7`
- `quickhack_synapse_burnout`  ←  `BaseStatusEffect.BaseBrainMelt_inline5`
- `status_burning`  ←  `AIQuickHackStatusEffect.HackOverheatBase_inline2`
- `w_expl_blackwall_npc_death_gameplay`  ←  `BaseStatusEffect.HauntedGunBlackWallForceKill_inline2`
- `w_expl_blackwall_shortcircuit`  ←  `BaseStatusEffect.CyberwareMalfunctionBlackwall_inline1`

## Electric & EMP  (7)

- `cpo_shocked_status`  ←  `BaseStatusEffect.CPO_Shocked_inline2`
- `idle_electric`  ←  `BaseStatusEffect.StrongArmsElecricActive_inline0`
- `p_discharge_connector`  ←  `Items.DischargeConnectorVFXEffector`
- `quickhack_sonic_shock`  ←  `BaseStatusEffect.BaseCommsNoise_inline3`
- `status_electricity_resistance`  ←  `Ability.HasElectricCoating_inline3`
- `status_electrocuted`  ←  `Ability.HasHealthMonitorBomb_inline7`
- `status_emp`  ←  `BaseStatusEffect.BaseEMP_inline3`

## Smoke, Gas & Dust  (6)

- `damage_smoke`  ←  `Spawn_glp.Drone_GLP_inline0`
- `enter_concrete`  ←  `Oda.Cemented_inline2`
- `status_cement_dust`  ←  `BaseStatusEffect.CementPowder_inline3`
- `status_sandstorm`  ←  `BaseStatusEffect.SandstormAbstract_inline0`
- `status_smoke_bomb`  ←  `BaseStatusEffect.SmokeBomb_inline3`
- `thrust_smoke`  ←  `Spawn_glp.Drone_GLP_inline3`

## Blackwall & Glitch  (9)

- `black_wall`  ←  `BaseStatusEffect.HauntedBlackwallAfterKill_inline3`
- `black_wall_activation`  ←  `BaseStatusEffect.HauntedBlackwallForceKill_inline9`
- `black_wall_upload`  ←  `BaseStatusEffect.HauntedBlackwallForceKill_inline6`
- `blackwall_loop`  ←  `Chimera.ChimeraBlackWallVFXStatusEffect_inline0`
- `glitch`  ←  `WorkspotStatus.JohnnySceneWorkspot_inline1`
- `hacking_glitch_low`  ←  `BaseStatusEffect.NetwatcherGeneral_inline0`
- `q305_cerberus_blackwall_glitch_heavy`  ←  `BaseStatusEffect.NoSandevistanGlitch_inline0`
- `vfx_blackwall_hack_npc_death`  ←  `BaseStatusEffect.SoMi_Q306_BlackwallHackQuestForceKill_inline2`
- `vfx_blackwall_hack_npc_upload`  ←  `BaseStatusEffect.HauntedGunBlackwallUpload_inline0`

## Wounds & Status  (18)

- `broken`  ←  `AdamSmasher.Wounded_inline0`
- `left_arm_destroyed`  ←  `Minotaur.LeftArmDestroyed_inline2`
- `mws_se5_03_blood_2`  ←  `BaseStatusEffect.mws_se5_03_damage_vfx_inline1`
- `right_arm_destroyed`  ←  `Minotaur.RightArmDestroyed_inline2`
- `status_bleeding`  ←  `BaseStatusEffect.Bleeding_inline4`
- `status_blinded`  ←  `BaseStatusEffect.SmasherICE_DisableCyberdeck_inline4`
- `status_braindance`  ←  `WorkspotStatus.Braindance_inline2`
- `status_drugged`  ←  `BaseStatusEffect.CombatStim_VeryHard_inline3`
- `status_drugged_heavy`  ←  `BaseStatusEffect.DruggedSevere_inline2`
- `status_drugged_low`  ←  `BaseStatusEffect.Poisoned_inline0`
- `status_knockdown`  ←  `BaseStatusEffect.Knockdown_inline4`
- `status_out_of_oxygen`  ←  `BaseStatusEffect.OutOfOxygen_inline2`
- `status_poison_resistance`  ←  `Ability.HasToxicCleanser_inline3`
- `status_stunned`  ←  `BaseStatusEffect.Stun_inline3`
- `status_wounded_l_arm`  ←  `BaseStatusEffect.CrippledArmLeft_inline0`
- `status_wounded_l_leg`  ←  `BaseStatusEffect.CrippledLegLeft_inline0`
- `status_wounded_r_arm`  ←  `BaseStatusEffect.CrippledArmRight_inline0`
- `status_wounded_r_leg`  ←  `BaseStatusEffect.CrippledLegRight_inline0`

## Hacks & Quickhacks  (22)

- `hacks_brain_bolt`  ←  `BaseStatusEffect.BrainMeltLevel4_inline6`
- `hacks_brain_bolt_kill`  ←  `BaseStatusEffect.HauntedGunBlackWallForceKill_inline11`
- `hacks_comms_noise`  ←  `BaseStatusEffect.BaseCommsNoise_inline7`
- `hacks_comms_noise_android`  ←  `BaseStatusEffect.BaseCommsNoise_inline8`
- `hacks_contagion`  ←  `BaseStatusEffect.BaseContagionPoison_inline5`
- `hacks_cyberware_malfunction`  ←  `BaseStatusEffect.OverloadLevel4_inline3`
- `hacks_locomotion_malfunction`  ←  `BaseStatusEffect.OverloadLevel3_inline2`
- `hacks_optics_malfunction`  ←  `BaseStatusEffect.ChimeraBaseQuickHackBlind_inline3`
- `hacks_system_collapse`  ←  `BaseStatusEffect.DeviceTrapHit_inline33`
- `hacks_weapon_malfunction`  ←  `BaseStatusEffect.WeaponMalfunctionRepeat_inline8`
- `hacks_weapon_malfunction_weapon_l`  ←  `BaseStatusEffect.WeaponMalfunctionRepeat_inline4`
- `quickhack_contagion`  ←  `BaseStatusEffect.BaseContagionPoison_inline0`
- `quickhack_cyberpsychosis`  ←  `BaseStatusEffect.BossMadness_inline3`
- `quickhack_cyberpsychosis_mech`  ←  `BaseStatusEffect.SetFriendly_inline12`
- `quickhack_cyberware_malfunction`  ←  `BaseStatusEffect.BossCyberwareMalfunction_inline3`
- `quickhack_locomotion_malfunction`  ←  `BaseStatusEffect.BossLocomotionMalfunction_inline16`
- `quickhack_memory_wipe`  ←  `BaseStatusEffect.MemoryWipe_inline3`
- `quickhack_ping`  ←  `BaseStatusEffect.Ping_inline3`
- `quickhack_reboot_optics`  ←  `BaseStatusEffect.BaseQuickHackBlind_inline1`
- `quickhack_request_backup`  ←  `BaseStatusEffect.WhistleLvl0_inline4`
- `quickhack_system_reset`  ←  `BaseStatusEffect.SystemCollapse_inline0`
- `quickhack_weapon_malfunction`  ←  `BaseStatusEffect.WeaponMalfunctionRepeat_inline17`

## Buffs & Perks  (20)

- `berserk`  ←  `BaseStatusEffect.BerserkPlayerBuff_inline0`
- `catch_me`  ←  `BaseStatusEffect.DetectorRushPlayerBuffCommon_inline2`
- `iconic_cyberware_ready`  ←  `BaseStatusEffect.IconicCyberwareCooldown_inline1`
- `leeroy_jenkins`  ←  `BaseStatusEffect.TroubleFinderPlayerBuffCommon_inline2`
- `optical_camo`  ←  `BaseStatusEffect.OpticalCamoPlayerBuffBase_inline0`
- `perk_edgerunner`  ←  `BaseStatusEffect.AdvancedBerserkPlayerBuff_inline0`
- `perk_edgerunner_player`  ←  `BaseStatusEffect.Tech_Master_Perk_3_VFX_inline0`
- `perk_overclock`  ←  `BaseStatusEffect.Intelligence_Central_Milestone_3_Overclock_Buff_inline4`
- `perk_rip_and_tear`  ←  `NewPerks.RipAndTearQuickmelee_Buff_inline6`
- `reflex_buster`  ←  `CyberwareAction.BloodPumpVFXObjectActionEffect_inline0`
- `smart_storage`  ←  `BaseStatusEffect.SmartStorageCooldown_inline0`
- `splinter_buff`  ←  `BaseStatusEffect.HealthRegeneration_inline2`
- `status_berserk`  ←  `BaseStatusEffect.BerserkNPCBuff_inline0`
- `status_decreased_stats`  ←  `BaseStatusEffect.Stat_Debuff_inline2`
- `status_fire_resistance`  ←  `Ability.HasFireproofSkin_inline3`
- `status_increased_stats`  ←  `BaseStatusEffect.Stat_Buff_inline0`
- `sudden_aid`  ←  `BaseStatusEffect.SuddenAidBuff_inline4`
- `vfx_fullscreen_second_heart`  ←  `BaseStatusEffect.SecondHeart_inline3`
- `weakspotWeak`  ←  `BaseStatusEffect.AdvancedBerserk_inline0`
- `weakspot_weak`  ←  `BaseStatusEffect.Berserker_inline1`

## Eyes & Cosmetic  (9)

- `cybermask`  ←  `CyberwareAction.CWMaskVFXObjectActionEffect_inline0`
- `eye_flare`  ←  `BaseStatusEffect.SeeThroughWalls_inline0`
- `eye_glow_gold`  ←  `BaseStatusEffect.SandevistanBuff_inline2`
- `eye_glow_red`  ←  `BaseStatusEffect.BossMadness_inline2`
- `eyes_closing_instant`  ←  `BaseStatusEffect.CyberwareInstallationAnimationBlackout_inline0`
- `eyes_opening`  ←  `BaseStatusEffect.CyberwareInstallationAnimationEnd_inline2`
- `eyes_opening_instant`  ←  `BaseStatusEffect.CyberwareInstallationAnimationEndFast_inline2`
- `glow_tattoo_constant`  ←  `BaseStatusEffect.GlowingTattoos_inline0`
- `glowing_eyes`  ←  `Character.maelstrom_base_inline1`

## Johnny & Story  (8)

- `fx_chainsword_idle`  ←  `Items.ChainswordIdleFX_inline0`
- `johnny_intro`  ←  `WorkspotStatus.JohnnySceneWorkspot_inline0`
- `johnny_sickness_lvl1`  ←  `BaseStatusEffect.q304_songbird_relic_shock_inline0`
- `johnny_sickness_lvl2`  ←  `BaseStatusEffect.JohnnySicknessMedium_inline0`
- `johnny_sickness_lvl3`  ←  `BaseStatusEffect.JohnnySicknessHeavy_inline0`
- `mws_se5_03_katana_attack`  ←  `BaseStatusEffect.mws_se5_03_katana_vfx_inline1`
- `q304_helicopter_rotor_hit`  ←  `BaseStatusEffect.q304_helicopter_rotor_effect_inline0`
- `q_ow_generic_ripperdoc_install_part`  ←  `BaseStatusEffect.CyberwareInstallationAnimationSFX_inline2`

## Misc  (5)

- `energy_off`  ←  `BaseStatusEffect.Berserker_inline0`
- `fx_damage_medium`  ←  `BaseStatusEffect.Parry_inline0`
- `idle_chemical`  ←  `BaseStatusEffect.StrongArmsChemicalActive_inline0`
- `idle_thermal`  ←  `BaseStatusEffect.StrongArmsThermalActive_inline0`
- `stand_inhale_drug_exhale`  ←  `BaseStatusEffect.CombatStim_Hard_inline4`
