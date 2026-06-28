This is a super early test of a new mod that is trying to create a system for mission creation in the game itself.

Its going to have bugs, its going to be hard to use.

I think the community can probably help work out the bugs and probably have someone familiar with managing repos and mods help develop this moving forawrd!



If you look at this reddit post you will see a video
https://www.reddit.com/r/cyberpunk2077mods/comments/1ui14q7/update_2_still_working_on_my_custom_in_game/

-----------------------------------
Lots of shit still needs to be worked on but most of the core features of the editor are working you can do some basic missions, and probably some super advanced...
What you can see in this clip is starting a new mission in the editor, adding an npc, setting up some nodes and having him do a path.

There is a posture system where you basically per object or npc can set a chain of events like a state machine, that state machine can also change postures... So you could effectively have a posture for patrolling, then a separate posture for high alert where the npc will act differently.
An example is a guard is pathing around an area, maybe you have a trigger when he hits a zone he says something to another npc, then that other npcs posture gets set to "Go Talk to Boss" he will then in that posture walk to the boss.  When he hits the trigger at the boss you can have him say his text, wait a few seconds.. Change the boss posture from idle to whatever.
Then boom change the posture of all the enemies to hostile.

Very simple mechanics can lead to very complex sequences.
Right now there are many holes in the logic and missing functions to really make this work, some harder stuff like making sure the movements to nodes doesn't have that little stutter, stuff like that.
I am not a write a shit ton of documentation guy and having ai crank out some huge doc most people won't read is also not worth the effort haha, but there are a ton of features.

As of right now its basically a cool mission maker toy or a sandbox toy actually.
I had to make a custom compile of CET to add a few functions it didn't have which sucks and I don't really want to bother asking them to like add it to the source, I am going to put all this up on github but if there is some brave soul that wants to try to get this working on their pc and play with it.

There is also a crashbug when you exit that game that I've not looked into!
