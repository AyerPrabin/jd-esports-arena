// ZULU's answer book: ~100 topics, each with the ways real JD players ask it (English, romanized Nepali with
// their spellings like "xa", "hunxa", "kasri", "hlo", and Devanagari) and a checked answer in English (en)
// and romanized Nepali (ne). Used three ways (owner, 9 Nov 2026):
//  1. small talk ("hlo", "thanks", "ok") is answered at once, no AI, so a greeting never gets a hand-off;
//  2. the best matching topics go into the AI prompt as checked answers, so the AI says the JD rule;
//  3. when every AI model fails, the best match is sent instead of "a moderator will reply".
// Keep answers in line with _shared/zulu.ts. Live things (times, seats, your points) stay with the AI.

export interface KBEntry { id: string; q: string; en: string | string[]; ne: string | string[]; dv?: string | string[]; small?: boolean; flag?: boolean }

const K: KBEntry[] = [
  // ── small talk ──
  { id: 'greet', small: true,
    q: 'hi|hello|hlo|helo|hlw|hey|hii|hiii|hy|hlo sir|hello sir|hi sir|hello dai|hlo dai|hi bro|hello bro|hi jd team|hello jd|hi zulu|hello zulu|namaste|namaskar|oi|uo|yo|sup|sir|dai|bro|good morning|good evening|good afternoon|gm|ge|k cha|k xa|के छ|नमस्ते|नमस्कार|हेलो|हाई',
    en: ['Hey! 👋 What do you need: tournaments, a free card, points or something else?', 'Hi! I\'m ZULU from JD Arena. Ask me anything about events, free cards, points or Free Fire.', 'Hello! 👋 How can I help? Tournaments, wallet, free card, challenges, just ask.'],
    ne: ['Namaste! 👋 K help chahiyo: tournament, free card, points ki aru kei?', 'Hello! Ma ZULU, JD Arena ko AI. Tournament, free card, points jun kura sodhnus.', 'Hi bro! 👋 K garna paryo? Tournament, wallet, free card, challenge, jei sodha.'],
    dv: ['नमस्ते! 👋 के मद्दत चाहियो: tournament, free card, points कि अरू केही?'] },
  { id: 'howareyou', small: true,
    q: 'how are you|how r u|hru|how are u|kasto cha|kasto xa|sanchai|sanchai cha|k gardai|k gardai xau|timi kasto xau|tapai lai kasto cha|whats up|wassup|k cha khabar|tapailai kasto chha|कस्तो छ|सन्चै',
    en: ['All good here, ready for some Booyah! 😄 How about you? Playing tonight?', 'Doing great! Just keeping an eye on tonight\'s rooms. What\'s up with you?'],
    ne: ['Ekdam thik cha bro! 😄 Timi kasto? Aaja khelne ho?', 'Sanchai! Aaja ko match ko tayari ma. Tapai lai k help chahiyo?'],
    dv: ['सन्चै छ! 😄 तपाईंलाई कस्तो छ? आज खेल्ने हो?'] },
  { id: 'thanks', small: true,
    q: 'thanks|thank you|thank u|thx|tq|ty|tysm|thanks sir|thank you sir|thanks dai|ok thanks|ok thank you|dhanyabad|dhanyawad|dhanybad|thanks bro|thank you zulu|धन्यवाद|धन्यबाद',
    en: ['Anytime! 🙌 Good luck in your next match.', 'No problem! Ping me if you need anything else.'],
    ne: ['Kei chaina bro! 🙌 Match ma all the best.', 'Hunxa! Aru kei chahiyo bhane sodhnus.'],
    dv: ['केही छैन! 🙌 म्याचमा शुभकामना।'] },
  { id: 'ok', small: true,
    q: 'ok|okay|okk|okey|oky|ok sir|ok dai|ok bro|k|kk|huss|hus|hass|has|hunxa|huncha|hunchha|thik cha|thik xa|la|la thik cha|done|alright|fine|got it|👍|👌|🙏|hmm|hm|oh|ohh|acha|achha|ठिक छ|हुन्छ|हस्',
    en: ['👍 Anything else, just ask.', 'Cool 👍 I\'m here if you need anything.'],
    ne: ['👍 Aru kei bhaye sodhnus hai.', 'Huss 👍 Kei chahiyo bhane ma yahi chu.'],
    dv: ['👍 अरू केही भए सोध्नुहोस्।'] },
  { id: 'bye', small: true,
    q: 'bye|bye bye|gn|good night|gud night|see you|see ya|cya|pachi kura garaula|pachi bolaula|jaanchu|ma gaye|tata|शुभ रात्री',
    en: ['Bye! 👋 See you in the room.', 'Good night! Rest well and come back for Booyah. 😄'],
    ne: ['Bye bye! 👋 Room ma bhetaula.', 'Good night bro! Bholi Booyah garaula. 😄'] },
  { id: 'overview', q: 'what should i know|what you know|what do you know|tell me about it|tell me about jd|what is jd arena|what is this app|what is this|how it works|how does it work|explain jd|k ho yo|yo k ho|jd arena k ho|ke ke cha|ke garna sakincha|bujhaideu|bujhau|sabai bhana|k k jannu parcha|new player guide',
    en: 'JD Arena in short:\n1) Free Fire tournaments every evening (Nepal time): squad, duo and solo, Best of 3, prize split 50/30/20.\n2) Join a free event with a free card or 15 points (new players get 1 free card until 8 Dec).\n3) Clash Squad challenges any time: 1v1 to 4v4 for points.\n4) Your wallet holds points: load with eSewa, withdraw your wins.\n5) Room ID and password come in notifications about 5 min before the match.\nWhat do you want to start with? /events/',
    ne: 'JD Arena chhito ma:\n1) Har beluka Free Fire tournament: squad, duo, solo, Best of 3, prize 50/30/20.\n2) Free event ma free card wa 15 points le join (naya player lai 8 Dec samma 1 free card).\n3) Jun bela pani Clash Squad challenge: 1v1 dekhi 4v4, points ko lagi.\n4) Wallet ma points: eSewa le load, jiteko withdraw.\n5) Room ID ra password match bhanda 5 min agadi notification ma aaucha.\nKe bata suru garne? /events/' },
  { id: 'whoareyou', small: true,
    q: 'who are you|who r u|are you bot|are you a bot|are you ai|are you human|are you real|real person|is this a bot|bot ho|timi ko ho|tapai ko hunuhuncha|manxe ho|manche ho|manxe ho ki|manxe ho ki kei aru ho|robot ho|zulu ko ho|zulu k ho|what is zulu|ai ho|तिमी को हो|तपाईं को हो',
    en: 'I\'m ZULU, JD Arena\'s AI assistant 🤖 I answer questions about tournaments, free cards, points, challenges and Free Fire 24/7, and I bring in a real JD team member when something needs a person (payments, prizes, disputes).',
    ne: 'Ma ZULU, JD Arena ko AI assistant ho 🤖 Tournament, free card, points, challenge ra Free Fire ko kura 24 ghanta answer garchu. Payment, prize, dispute jasto kura ma JD team ko manxe bolauchu.',
    dv: 'म ZULU, JD Arena को AI assistant हुँ 🤖 Tournament, free card, points र Free Fire का कुरा २४ घण्टा जवाफ दिन्छु। Payment, prize जस्ता कुरामा JD team को मान्छे बोलाउँछु।' },
  { id: 'whomade', q: 'who made you|who built you|who created you|who made zulu|timi lai kasle banayo|kasle banayo|jd ko owner ko ho|owner ko ho|jd ko malik ko ho|who is the owner|who is prabin|ayer fire ko ho|who runs jd|admin ko ho',
    en: 'JD Esports Arena is run by Prabin Ayer (AyerFire, @ayer_fire on TikTok), and he built me, ZULU, to help players any time of day.',
    ne: 'JD Esports Arena Prabin Ayer (AyerFire, TikTok ma @ayer_fire) le chalaunu hunchha, ra mailai ZULU pani unai le banaunu bhako ho, players lai 24 ghanta help garna.' },
  { id: 'nepali', small: true, q: 'can you speak nepali|nepali ma bola|nepali ma bolnus|nepali aauxa|nepali aaucha|nepali bujhchau|nepali ma kura garau|nepali ma kura gara|nplai ma kura garau|speak nepali|nepali bolna aaucha',
    en: 'Yes! I speak Nepali too. Write to me however you like: English, Nepali or romanized Nepali.',
    ne: 'Aaucha ni! 😄 Nepali, English, jasari lekhe pani bujhchu. K sodhne ho, bhannus.' },
  { id: 'joke', q: 'tell me a joke|joke sunau|joke bhana|euta joke|make me laugh|hasau|funny kura',
    en: ['Why did the squad bring a ladder to the match? To reach the top of the leaderboard. 😄', 'My favourite exercise? Running from the zone. 🏃‍♂️'],
    ne: ['Zone le pani hamro team lai jasto chito daudauna sakdaina. 😄', 'Gloo wall jasto strong friendship chahiyo bro, 1 second ma pani tutdaina. 😄'] },
  { id: 'bored', q: 'bored|i am bored|boring|kei garna chaina|time pass|bore bhayo|bore lagyo|k garu',
    en: 'Bored? Try a Clash Squad challenge: 1v1 up to 4v4 for points, it\'s the quickest way to play and win. /challenges/',
    ne: 'Bore lagyo? Clash Squad challenge khela: 1v1 dekhi 4v4 samma points ko lagi, sabai bhanda chito khelne ra jitne tarika. /challenges/' },

  // ── the app and getting started ──
  { id: 'whatisjd', q: 'what is jd|what is jd arena|what is jd esports|jd esports k ho|jd arena k ho|yo app k ho|what is this app|what is this site|yo k ho|yo site k ho|jd k ho|how does jd work|jd kasari chalcha',
    en: 'JD Esports Arena is a Free Fire tournament platform in Nepal: join BR tournaments (free with a card or 15 points, or paid), play Clash Squad challenges for points, and prizes go straight into your JD wallet. Start at /events/',
    ne: 'JD Esports Arena Nepal ko Free Fire tournament platform ho: BR tournament join gara (free card wa 15 points, ki paid), Clash Squad challenge khela, prize sidhai JD wallet ma aaucha. /events/' },
  { id: 'newplayer', q: 'i am new|new player|new user|naya ho|ma naya hu|first time|how to start|kaha bata suru garne|suru kasari garne|start garne kasari|help me start|guide me|k garnu parcha|naya player|मैले कसरी सुरु गर्ने',
    en: 'Welcome! 1) Install the app from /download/ (Android) or use jdesport.co.uk on iPhone. 2) Sign up. 3) Add your Free Fire UID and name in your profile (new players get 1 welcome free card). 4) Open /events/, tap Join, enter your squad. 5) Tap "Confirm you\'re playing" before the event. The room ID arrives in notifications about 5 minutes before the match.',
    ne: 'Swagat cha! 1) Android ma /download/ bata app install gara (iPhone ma jdesport.co.uk). 2) Sign up gara. 3) Profile ma Free Fire UID ra name hala (naya player le 1 welcome free card paucha). 4) /events/ ma Join thichera squad hala. 5) Event agadi "Confirm you\'re playing" thich. Room ID match bhanda 5 min agadi notification ma aaucha.' },
  { id: 'download', q: 'download app|download|apk|app kaha paine|app kaha cha|app link|how to download|app download kasari|install app|play store|play store ma cha|jd app|app chahiyo|apk link|app download garne|update app|app update|latest app|एप कहाँ',
    en: 'Android: download the JD Arena app from jdesport.co.uk/download/ (it isn\'t on the Play Store; allow "install unknown apps" once). iPhone: just use jdesport.co.uk in Safari. /download/',
    ne: 'Android ko lagi jdesport.co.uk/download/ bata JD Arena app download gara (Play Store ma chaina, "install unknown apps" ek choti allow gara). iPhone ma Safari ma jdesport.co.uk nai chalau. /download/' },
  { id: 'iphone', q: 'iphone|ios|apple|iphone ma app|iphone ma kasari|ipad|iphone app chaina|safari',
    en: 'On iPhone and iPad you don\'t need an app: open jdesport.co.uk in Safari, sign in and everything works there.',
    ne: 'iPhone/iPad ma app chahidaina: Safari ma jdesport.co.uk khol, sign in gara, sabai tyahi chalcha.' },
  { id: 'signup', q: 'create account|sign up|signup|account kasari banaune|account banaune|register account|login kasari|login|log in|how to login|gmail le login|google login|account chaina|account kholne',
    en: 'Tap Sign in on jdesport.co.uk or in the app and use Google or email + password. Then add your Free Fire UID and in-game name in your profile.',
    ne: 'jdesport.co.uk wa app ma Sign in thich, Google wa email + password le account bana. Ani profile ma Free Fire UID ra in-game name hala.' },
  { id: 'loginerror', q: 'google login not working|login hudaina|login vayena|login bhayena|403|disallowed useragent|sign in problem|cant login|cannot login|login error|login garna mildaina|account khuldaina',
    en: 'If Google sign-in fails (403 disallowed_useragent), you opened the site inside TikTok/Facebook/Messenger. Open jdesport.co.uk in Chrome (⋮ menu > Open in browser), use the JD app, or log in with email and password.',
    ne: 'Google login bhayena (403) bhane TikTok/Facebook bhitra site kholeko ho. Chrome ma jdesport.co.uk khol (⋮ > Open in browser), JD app chalau, wa email + password le login gara.' },
  { id: 'forgotpw', q: 'forgot password|password birsiye|password birse|reset password|password change|password bhulye|password k thiyo',
    en: 'Tap Sign in > Forgot password and we email you a reset link. If you signed up with Google, just use Continue with Google.',
    ne: 'Sign in > Forgot password thich, email ma reset link aaucha. Google le account banako bhaye Continue with Google thiche hunchha.' },
  { id: 'uid', q: 'game uid|add uid|uid kaha halne|uid change|in game name|ign change|ign|name change|uid halne|ff uid|free fire id|id halne|mero uid',
    en: 'Tap your name > Game UID & name to add or change your Free Fire UID and in-game name. Admins use it to check who played.',
    ne: 'Aafno name thichera Game UID & name ma Free Fire UID ra in-game name hala wa change gara. Admin le tyo herera ko khelyo check garcha.' },
  { id: 'blackscreen', q: 'black screen|app black|black screen aayo|app khulena|app khuldaina|app crash|white screen|loading matra|app not working|app chaldaina|app hang|app bigriyo|blank screen|kei dekhindaina',
    en: 'Update the app from /download/ (remove the old one first if it still shows black), then open it and sign in again. If it\'s still blank, use jdesport.co.uk in Chrome meanwhile.',
    ne: '/download/ bata latest app download gara (black nai dekhaye purano delete garera install gara), ani pheri sign in gara. Ajhai blank bhaye Chrome ma jdesport.co.uk chalau.' },
  { id: 'notif', q: 'notification aayena|no notification|notification audaina|alerts not coming|room id notification|notification off|notification kasari|no alerts|alert aayena|sound aayena',
    en: 'Update the app from /download/, sign in inside the app and tap Allow. Then check phone Settings > Apps > JD Arena > Notifications is on (Xiaomi/Oppo/Vivo/Realme: allow Autostart and set Battery to No restrictions).',
    ne: '/download/ bata app update gara, app bhitra sign in garera Allow thich. Phone Settings > Apps > JD Arena > Notifications on cha ki hera (Xiaomi/Oppo/Vivo: Autostart allow, Battery "No restrictions").' },
  { id: 'friend', q: 'add friend|friend kasari add|squad banaune|team banaune|team kasari banaune|squad kasari banaune|friend add garne|squad ma add|teammate add|add teammate|squad banaun lai add friend|how to make squad',
    en: 'Use the Add friend option in Messages to add players and make your squad, or share the app with your Free Fire friends. In a tournament the captain joins and puts all 4 players in "Verify your squad".',
    ne: 'Messages ma Add friend option bata friend add garera squad bana, wa Free Fire ka saathi lai app share gara. Tournament ma captain le join garera "Verify your squad" ma 4 jana ko name/UID halcha.' },
  { id: 'solo', q: 'i am alone|squad chaina|team chaina|solo khelna|ekla khelne|ma eklai chu|ekla|no squad|no team|friend chaina|solo khelna milcha|eutai chu',
    en: 'No squad yet? Look for Solo events on /events/, or play 1v1 Clash Squad challenges for points on your own. /challenges/',
    ne: 'Squad chaina? /events/ ma Solo event hera, natra 1v1 Clash Squad challenge khelera points jitna sakchau. /challenges/' },
  { id: 'logo', q: 'logo change|logo update|logo dekhena|logo change vayena|logo kasari halne|squad logo|team logo|logo milaidinu|logo bigriyo',
    en: 'Your saved squad logo is used from your next event; an event you already joined keeps the old one. Change it when you join (tap Change).',
    ne: 'Naya logo next event dekhi aaucha; already join gareko event ma purano nai rahancha. Join garda Change thichera logo change gara.' },
  { id: 'squadname', q: 'squad name change|team name change|name change garne|squad ko name|team ko naam|naam change',
    en: 'You can change your squad name and line-up in "Verify your squad" on your ticket until the room details are sent.',
    ne: 'Ticket ko "Verify your squad" ma room details nao aaunjel squad name ra line-up change garna milcha.' },

  // ── tournaments ──
  { id: 'join', q: 'how to join|join kasari|join kasari garne|tournament ma kasari|tournament join|register kasari|entry kasari|kasari khelne|how to play|how to register|tournament kasari khelne|join garne|khelna kasari|मैले कसरी join गर्ने',
    en: 'Open /events/, tap Join on an event, enter your squad name, device and WhatsApp once, pick a free card or 15 points (free events), tick the rules and tap Confirm & join. Then tap "Confirm you\'re playing" 48h to 24h before the start.',
    ne: '/events/ khol, event ma Join thich, squad name, device ra WhatsApp hal, free card wa 15 points chhan (free event), rules tick garera Confirm & join. Ani start bhanda 48h dekhi 24h agadi "Confirm you\'re playing" thich.' },
  { id: 'free', q: 'free tournament|free ma khelna|i want to play free|free entry|free event|free match|paisa bina|without money|free ma join|free scrim|free ma khelne|free hunxa',
    en: 'Free events need a free card or 15 points (you pick when joining) and pay a Rs 180 prize (50/30/20). New players get 1 welcome card after adding their UID, and you can earn one at /wallet/#promo.',
    ne: 'Free event ma free card wa 15 points lagcha (join garda chhannu) ra prize Rs 180 (50/30/20). Naya player le UID halepachi 1 welcome card paucha, aru card /wallet/#promo bata.' },
  { id: 'freecard', q: 'free card|free card kasari|free card kasari paune|card kasari paune|ticket kasari paune|free ticket|free card chahiyo|card dinu|free card dinu|voucher|free entry card|card kaha bata',
    en: 'Your first free card: follow @ayer_fire on TikTok, comment on and repost 3 of our videos with your JD username in each comment, then send it in Wallet > Free entry. After that, each card needs your own video about JD Arena showing how to download it. A mod checks and adds the card. /wallet/#promo',
    ne: 'Pahilo free card: TikTok ma @ayer_fire follow gara, 3 ota video ma JD username lekhera comment ra repost gara, ani Wallet > Free entry ma pathau. Tyespachi har card ko lagi JD Arena ko download garne tarika dekhaune aafno video chahincha. Mod le check garera card dincha. /wallet/#promo' },
  { id: 'freecardmissing', q: 'card aayena|ticket aayena|free card aayena|maile follow gare|follow like comment repost gareko|card pako chaina|ticket aaile samma aayena|card kina aayena|repost gare tara|follow gareko xu',
    en: 'Did you send it in Wallet > Free entry (/wallet/#promo)? A mod checks each claim by hand, so it can take a while. The follow card is only once per player; later cards need a video about JD Arena.',
    ne: 'Wallet > Free entry (/wallet/#promo) ma pathayau? Mod le haat le check garcha, ali time lagna sakcha. Follow wala card ek choti matra paincha; tyespachi video chahincha.' },
  { id: 'welcomecard', q: 'welcome card|welcome gift|naya player card|new player card|first card free|welcome bonus|signup bonus',
    en: 'Until 8 Dec 2026, new players who signed up since 8 Nov get 1 welcome free card (7 days) the first time they save their Free Fire UID in the profile.',
    ne: '8 Dec 2026 samma, 8 Nov pachi account banaune naya player le profile ma pahilo choti Free Fire UID save garda 1 welcome free card (7 din) paucha.' },
  { id: 'fifteen', q: '15 points|15 point|15 point kina|15 points katyo|why 15 points|points le join|points bata join|15 ma join',
    en: 'Free events ask for a free card or 15 points, your choice when joining. If the event is cancelled or you withdraw 24h+ before, the 15 come back.',
    ne: 'Free event ma free card wa 15 points, join garda aafai chhannu. Event cancel bhaye wa 24h agadi withdraw garda 15 points pharkancha.' },
  { id: 'slotplease', flag: false, q: 'slot dinu|slot dinu na|slot dinus|join gardinu|join gardinu na|mero team lai haldinu|entry dinu|entry gardinu|malai slot|slot chahiyo|give me slot|add my team|team halidinu|add garidinu|ma lai ni haldinu|ticket dinu|slot milaidinu|entry gardinna|haldinu|team haldinu|mero team lai ni haldinu|hamro team lai entry',
    en: 'Mods can\'t add squads by hand: join yourself from /events/ with a free card or 15 points. If it\'s full, join the waitlist and tap "Pay 20 points for a place" on your ticket.',
    ne: 'Mod le haat le team haldina mildaina: /events/ bata aafai join gara (free card wa 15 points). Full bhaye waitlist ma basera ticket ma "Pay 20 points for a place" thich.' },
  { id: 'full', q: 'full|event full|slot full|seat full|waitlist|waiting list|line ma|waitlist ma|full bhayo|slot khali cha|slot khali xa|khali slot|space cha|seat left',
    en: 'When an event is full you go on the waitlist. In free events the waitlist doesn\'t move up for free: tap "Pay 20 points for a place" on your ticket (closes 30 min before). Paid events move up automatically.',
    ne: 'Event full bhaye waitlist ma parcha. Free event ma free ma mathi aaudaina: ticket ma "Pay 20 points for a place" thich (30 min agadi band). Paid event ma aafai mathi aaucha.' },
  { id: 'confirm', q: 'confirm|confirm playing|confirm garne|confirm kasari|ready|squad ready|we are ready|ready cha|confirm you re playing|confirm garnu parcha|confirm kina',
    en: 'Tap "Confirm you\'re playing" on your ticket (home page event card). It opens 48h before start and must be done by 24h before, or the seat goes to the waitlist.',
    ne: 'Ticket ma (home page event card) "Confirm you\'re playing" thich. Start bhanda 48h agadi khulcha, 24h agadi samma garena bhane seat waitlist lai jancha.' },
  { id: 'removed', q: 'removed|mero team hatayo|squad removed|kina hatayo|why removed|nikaliyo|event bata hatayo|ticket gayo|slot gayo',
    en: 'Squads are removed when they don\'t tap "Confirm you\'re playing" by 24h before the start, and their entry comes back. Check your Alerts and /wallet/ history for the exact reason and refund.',
    ne: 'Start bhanda 24h agadi samma "Confirm you\'re playing" nathiche team hatcha, entry pharkancha. Exact karan ra refund Alerts ra /wallet/ history ma hera.' },
  { id: 'roomid', q: 'room id|room id kaha|password kaha|room code|room id kaha aaucha|how to see room id|id pass|id password|room kaile aaucha|room id aayena|room pass|id pass kaha|room code kasari paune|password kaile|where password|where is the password|password shown|password kaha dekhincha|id pass kaha aaucha',
    en: 'The Room ID and password come about 5 minutes before the match: in a notification, in Alerts (Messages) and on your ticket. Keep the app open and alerts on.',
    ne: 'Room ID ra password match bhanda 5 min agadi aaucha: notification, Messages ko Alerts ra ticket ma. App kholera alert on rakha.' },
  { id: 'slotnum', q: 'slot number|which slot|kun slot|mero slot|slot kaha|seat number|kun seat|slot kati|position number',
    en: 'Your slot number is on your ticket and in the room notification. Sit in the seat that matches it in the custom room.',
    ne: 'Slot number ticket ra room notification ma huncha. Custom room ma tyahi number ko seat ma basa.' },
  { id: 'enter10', q: 'late|room ma late|kati time samma|10 minute|room ma kaile basne|late bhaye|late join',
    en: 'Enter the room within 10 minutes of the Room ID being shared, with your full squad together, in your slot\'s seat.',
    ne: 'Room ID aaye pachi 10 min bhitra pura squad sangai room ma basa, aafno slot ko seat ma.' },
  { id: 'rules', q: 'rules|rule|niyam|banned character|ban character|kun character ban|which character banned|character ban cha|skill ban|banned skill|orion ban|sonia|dimitri|ryden|ban list character',
    en: 'The main tournament rules:\n1) Full squad enters the room together, within 10 min of the Room ID, and sits in its slot number.\n2) Banned skills: Orion, Sonia, Dimitri and Ryden.\n3) No two players in a squad with the same active skill.\n4) No zone pushing, no hacks, no rude language.\n5) Join only if you will play: 3 no-shows = 1 month ban.\n6) Points: placement + kills added over all 3 matches, prize 50/30/20.\nAll rules with pictures: /rules/',
    ne: 'Main rules:\n1) Pura squad sangai room ma, Room ID aayeko 10 min bhitra, aafno slot number ma basnu parcha.\n2) Ban skill: Orion, Sonia, Dimitri ra Ryden.\n3) Eutai squad ma 2 jana le same active skill chalauna paudaina.\n4) Zone push, hack ra gali ban.\n5) Khelne bhaye matra join: 3 choti nakhele 1 mahina ban.\n6) Point: 3 ota match ko placement + kill jodincha, prize 50/30/20.\nSabai rules photo sanga: /rules/' },
  { id: 'roomset', q: 'gun attribute|gun attributes|skill on|character skill|room setting|room settings|custom room setting|zone kasto|full map',
    en: 'Tournament rooms: gun attributes OFF, character skills ON, full map with the normal zone, every match.',
    ne: 'Tournament room: gun attributes OFF, character skill ON, full map normal zone, har match.' },
  { id: 'map', q: 'which map|kun map|map kun ho|bermuda|purgatory|kalahari|nexterra|solara|alpine|map kati ota',
    en: 'Each event card shows its map. The BR map pool now is Bermuda, Purgatory, Kalahari, NeXTerra and Solara (Alpine was removed).',
    ne: 'Har event card ma map lekheko huncha. Ahile BR map: Bermuda, Purgatory, Kalahari, NeXTerra ra Solara (Alpine hatiyo).' },
  { id: 'noshow', q: 'no show|join gare tara khelena|didnt play|nakhele ke huncha|khelna sakina|absent|miss bhayo|match miss|ban kina|one month ban',
    en: 'A squad that joins and doesn\'t play gets a warning and is removed from its other upcoming events; 3 no-shows = banned from JD tournaments for 1 month. Only join if you\'ll play.',
    ne: 'Join garera nakhele warning aaucha ra aru event bata pani hatcha; 3 choti bhaye 1 mahina ban. Khelne bhaye matra join gara.' },
  { id: 'verify', q: 'verify squad|verify|line up|lineup|player name halne|uid halne squad|verify kasari|sub player|substitute|verify garna mildaina|name accept bhayena',
    en: 'Tap "🛡️ Verify your squad" on your ticket: real squad name plus the 4 players (and up to 2 subs) with exact in-game names and UIDs, captain included. Editable until room details go out.',
    ne: 'Ticket ma "🛡️ Verify your squad" thich: squad ko real name ra 4 jana (2 sub samma) ko exact in-game name ra UID, captain pani. Room details naaaunjel edit milcha.' },
  { id: 'modes', q: 'solo duo squad|solo event|duo event|squad event|mode|kun mode|4 jana|2 jana|kati jana chahincha|how many players|team ma kati jana|solo or squad|squad or solo|solo ho ki squad|squad ho ki solo|solo ho|squad ho|duo ho|is it solo|is it squad|is it duo|solo match|duo match|solo ma|ekla khelne event',
    en: 'Each event card shows its mode: Squad (4 players), Duo (2) or Solo (just you, no squad, no line-up to verify). One room holds 12 squads, 24 duos or 48 solo players. Tell me the event name and I will say its mode.',
    ne: 'Event card ma mode lekheko huncha: Squad (4 jana), Duo (2 jana) wa Solo (timi eklai, squad ra verify chahindaina). Eutai room ma 12 squad, 24 duo wa 48 solo. Event ko naam bhana, mode bhanchu.' },
  { id: 'groups', q: 'group|groups|semi final|semifinal|grand final|final|stage|group stage|draw',
    en: 'If more join than one room holds, JD draws random groups 2 hours before the start. Then groups, semi-finals (4+ groups) and a Grand Final where the whole prize is played for. Nobody pays again.',
    ne: 'Eutai room bhanda badi join bhaye start bhanda 2 ghanta agadi random group banchha. Group, semi-final (4+ group) ra Grand Final, prize Grand Final ma. Pheri paisa tirnu pardaina.' },
  { id: 'scoring', q: 'points system|point system|how points|kati point|point kasari|kill point|placement point|booyah point|1st kati point|scoring|point table|kasari point dincha|kill ko point',
    en: 'BR scoring every match: placement points (1st 12, 2nd 9, 3rd 8, 4th 7, 5th 6, 6th 5, 7th 4, 8th 3, 9th 2, 10th 1) plus 1 point per kill. All matches add up; the highest total wins.',
    ne: 'BR ma har match: position point (1st 12, 2nd 9, 3rd 8, 4th 7, 5th 6, 6th 5, 7th 4, 8th 3, 9th 2, 10th 1) + har kill 1 point. Sabai match jodincha, sabai bhanda dherai point wala jitcha.' },
  { id: 'bo3', q: 'best of 3|bo3|best of three|2 jitne jitcha|win 2|2 ota jityo bhane|3 ota match|3 match khelnu parcha|if 3 squad win each one|each win one|sabai le euta jityo|win garyo bhane khatam|who wins 2|2 match jitepachi',
    en: 'In BR "Best of 3" all 3 matches are always played. It\'s on points, not "first to win 2": placement + kill points from every match add up and the highest total wins. So if 3 squads each win one match, the total points decide. (In Clash Squad, best of 3 means first to win 2.)',
    ne: 'BR ko "Best of 3" ma 3 ota match sabai khelincha. Yo point basis ho, "2 jitne jitcha" haina: har match ko position + kill point jodincha, total dherai wala jitcha. 3 team le euta-euta jite pani total point le decide garcha. (Clash Squad ma chai best of 3 = 2 jitne jitcha.)' },
  { id: 'matches', q: 'kati ota match|how many matches|kati match|match kati ota|how many games|kati game|kati round',
    en: 'The event card shows how many matches (e.g. "BR · Best of 3" = 3 matches). All of them are played and the points add up.',
    ne: 'Event card ma kati match lekheko huncha (jastai "BR · Best of 3" = 3 match). Sabai khelincha ra point jodincha.' },
  { id: 'tie', q: 'same point|equal point|tie|draw|barabar point|point same bhaye|tie bhaye',
    en: 'If squads end on equal points, the JD team (or the event\'s host) decides from the official room results. If you think your result is wrong, send a screenshot to support: +977 986-8813682.',
    ne: 'Point barabar bhaye JD team (wa host) le official room result herera decide garcha. Result galat lagyo bhane screenshot support lai pathau: +977 986-8813682.' },
  { id: 'prize', q: 'prize|prize kati|prize money|1st prize|2nd prize|3rd prize|prize distribution|prize kasari bandcha|prize split|reward|reward kati|kati paincha|winner lai kati|prize pool',
    en: 'Every JD prize pool splits 50% / 30% / 20% for 1st, 2nd and 3rd. Free events pay Rs 180: Rs 90, Rs 54 and Rs 36. Partner-host events are paid by that host.',
    ne: 'JD ko har prize 1st 50%, 2nd 30%, 3rd 20%. Free event ko Rs 180: Rs 90, Rs 54 ra Rs 36. Partner host ko event ko prize tyo host le nai dincha.' },
  { id: 'prizewhere', q: 'prize kaha aaucha|prize aayena|prize kaile|prize kasari paune|prize money kaha|jiteko paisa|prize pako chaina|winner prize|prize wallet',
    en: 'JD prizes are paid automatically into your points wallet when results are published; check /wallet/ history. Then withdraw to eSewa from the wallet. If it\'s missing, send your username and a screenshot to +977 986-8813682.',
    ne: 'Result publish huna sath JD prize aafai points wallet ma aaucha; /wallet/ history hera. Ani wallet bata eSewa ma withdraw gara. Aayena bhane username ra screenshot +977 986-8813682 ma pathau.', flag: true },
  { id: 'results', q: 'result|results|result kaha|who won|ko jityo|winner ko|standings|result aayo|result kaile|point table kaha',
    en: 'Results go up on the home page and in your Alerts after each event; the season table is at /leaderboard.html',
    ne: 'Har event pachi result home page ra Alerts ma aaucha; season table /leaderboard.html ma.' },
  { id: 'leaderboard', q: 'leaderboard|rank|ranking|top team|season ranking|mero rank',
    en: 'The season leaderboard (squad events only) is at /leaderboard.html. Your own rank and stats are on /profile/.',
    ne: 'Season leaderboard (squad event matra) /leaderboard.html ma. Aafno rank ra stats /profile/ ma.' },
  { id: 'adminplay', q: 'admin khelcha|admin plays|owner plays|admin le khelyo|ancient ogs|admin ko team|admin cheat|admin le prize|is it fair admin',
    en: 'The owner sometimes plays just for fun with the same rules and never takes a prize: if his squad places, that prize goes to the next squad and everyone below moves up.',
    ne: 'Owner kahile kahi ramailo ko lagi same rule ma khelnu huncha, tara prize kahile lidainan: unko team top ma aaye prize arko team lai jancha, tala ka sabai ek step mathi.' },
  { id: 'host', q: 'host|hosted by|host ko event|partner host|host event|bs gaming|host le prize|host ko prize|scrim host|host ko scrim',
    en: 'Events marked "Hosted by @name" are run by a partner scrim host on JD Arena. You join like a free event (card or 15 points), and that host runs the room and pays the prize directly, not JD.',
    ne: '"Hosted by @name" bhayeko event partner scrim host le chalaucha. Free event jastai join huncha (card wa 15 points), room ra prize tyo host le nai handle garcha, JD le haina.' },
  { id: 'becomehost', q: 'become host|host banna|host banaidinu|host hunu|i want to host|scrim host banna|host kasari banne|host role',
    en: 'JD invites scrim hosts to run events here. Send your TikTok ID and the email on your JD account, and the JD team will look at it (no promise).',
    ne: 'JD le scrim host lai invite garcha. Aafno TikTok ID ra JD account ko email pathau, JD team le herchha (pakka bhanna sakdina).', flag: true },
  { id: 'becomemod', q: 'become mod|mod banna|mod banaidinu|moderator|mod kasari|mod chahiyo|mod hunu',
    en: 'JD picks mods from its best promoters (players who make videos about JD Arena). It\'s never guaranteed; the owner decides.',
    ne: 'JD ko best promoter (JD ko video banaune) haru madhye bata mod chhaniyo. Pakka hudaina, owner le decide garnu huncha.' },
  { id: 'cancelled', q: 'cancel|cancelled|event cancel|match cancel|tournament cancel|cancel bhayo|cancel kina|refund cancel|game cancel',
    en: 'When an event is cancelled, the entry points come back to your JD wallet automatically (you\'ll see a "Refund" line in /wallet/ history).',
    ne: 'Event cancel bhaye entry points aafai JD wallet ma pharkancha (/wallet/ history ma "Refund" line).' },
  { id: 'nighttime', q: 'day time|afternoon|din ma|diuso|morning tournament|always night|rati matra|time change|early time|din ma scrim',
    en: 'Most events run in the evening (Nepal time) because that\'s when hosts and most squads are free. New times show up on /events/ and in your alerts.',
    ne: 'Dherai jaso event belukā/rati huncha kina bhane host ra dherai team tyo bela free hunchan. Naya time /events/ ra alert ma aaucha.' },
  { id: 'nexttour', q: 'next tournament|next match|aaja match cha|aaja ko tournament|aaja tournament|when is tournament|tournament kaile|match kaile|kati baje|time kati|next scrim|bholi match|tonight',
    en: 'All upcoming events with times and open seats are on /events/.',
    ne: 'Aaune sabai event, time ra khali seat /events/ ma cha.' },
  { id: 'platform', q: 'emulator|pc ma khelna|laptop|pc player|mobile only|emulator allowed|bluestacks|pc milcha',
    en: 'Each event card says if it\'s mobile only; otherwise mixed is allowed. On PC, the JD Frag Engine can boost your emulator FPS. /optimizer/',
    ne: 'Event card ma "mobile only" lekheko bhaye mobile matra; natra mixed milcha. PC ma JD Frag Engine le emulator FPS badhaucha. /optimizer/' },
  { id: 'mega', q: 'mega|mega event|big tournament|thulo tournament|big prize|dherai prize',
    en: 'Bigger prizes are in the paid and MEGA events on /events/. If a MEGA event doesn\'t reach its minimum squads, everyone gets their entry back.',
    ne: 'Thulo prize paid ra MEGA event ma huncha (/events/). MEGA ma minimum team pugena bhane sabai ko entry pharkancha.' },

  // ── wallet and points ──
  { id: 'load', q: 'load points|points load|points kasari load|load kasari|load garne|esewa|topup|top up|recharge|point kinne|points kasari halne|buy points|paisa halne|qr|esewa qr|esewa bata',
    en: 'Wallet > Load: pay the eSewa QR with your username in the remarks, then upload the payment screenshot on the wallet page. Points are added after the admin checks it. 1 point = Rs 1. /wallet/#load',
    ne: 'Wallet > Load: eSewa QR ma paisa pathau (remarks ma username), ani wallet page ma payment screenshot upload gara. Admin le check garepachi points aaucha. 1 point = Rs 1. /wallet/#load' },
  { id: 'loadpending', q: 'points aayena|load aayena|load pending|plz fast load|fast load|load bhayena|paisa pathaye tara|points add bhayena|screenshot pathaye|load kaile|point aako chaina|load check',
    en: 'Points come after the admin checks your eSewa screenshot (usually a few hours). Make sure you uploaded it on the wallet page with your username in the remarks. Still missing after that? A JD team member will check.',
    ne: 'Admin le eSewa screenshot check garepachi points aaucha (prayah kehi ghanta). Wallet page ma screenshot upload gareu ra remarks ma username lekheu? Tyespachi pani aayena bhane JD team le check garcha.', flag: true },
  { id: 'withdraw', q: 'withdraw|withdraw kasari|paisa kasari nikalne|paisa nikalne|cash out|esewa ma pathaune|withdrawal|withdraw garne|paisa linu|points to money',
    en: 'Wallet > Withdraw to your own eSewa: minimum 100 points, 1% fee (100 points sends Rs 99). It\'s sent by hand, usually within a day. You need your 6-number wallet PIN. /wallet/',
    ne: 'Wallet > Withdraw bata aafno eSewa ma: kam se kam 100 points, 1% fee (100 points = Rs 99). Haat le pathaincha, prayah 1 din bhitra. 6 number ko wallet PIN chahincha. /wallet/' },
  { id: 'withdrawpending', q: 'withdraw aayena|withdraw pending|paisa aayena esewa|withdraw kaile aaucha|withdraw bhayena|esewa ma aayena|withdraw reject',
    en: 'Withdrawals are sent by hand, usually within a day. A rejected withdrawal puts the points back in your wallet. If it\'s been longer, a JD team member will check.',
    ne: 'Withdraw haat le pathaincha, prayah 1 din bhitra. Reject bhaye points wallet mai pharkancha. Dherai bhayo bhane JD team le check garcha.', flag: true },
  { id: 'pin', q: 'wallet pin|pin|pin kasari|pin banaune|create pin|6 digit|pin change|pin chahiyo',
    en: 'You need a 6-number wallet PIN to load or withdraw (not to join events). The wallet page asks you to create it; change it there with your current PIN. Never share it with anyone, not even JD.',
    ne: 'Load wa withdraw garna 6 number ko wallet PIN chahincha (event join garna haina). Wallet page le banauna bhancha; current PIN halera change garna milcha. Kasailai pani nabhana, JD lai pani.' },
  { id: 'forgotpin', q: 'forgot pin|pin birse|pin birsiye|pin locked|pin lock|wrong pin|pin bhulye|reset pin',
    en: 'Tap "Forgot PIN?" on the PIN screen and verify with your account\'s Google sign-in or a Gmail link, then set a new PIN. Withdrawals pause for 24h after a reset. 5 wrong tries lock it for 30 minutes.',
    ne: 'PIN screen ma "Forgot PIN?" thichera account ko Google wa Gmail link le verify gara, naya PIN rakha. Reset pachi 24h withdraw band huncha. 5 choti galat = 30 min lock.' },
  { id: 'refundrules', q: 'refund|refund kaile|refund kasari|refund milcha|withdraw from event|event chhodne|leave event|unregister|cancel my entry|entry firta|paisa firta',
    en: 'Leaving an event 24h+ before the start = full entry back; in the last 24 hours = 10% back; nothing once the room details are out. Cancelled events and removed squads get their entry back automatically. Refunds are points in your JD wallet.',
    ne: 'Start bhanda 24h agadi chhode pura entry firta; antim 24h ma 10% matra; room details aaye pachi kei pani hudaina. Cancel bhayeko event ra hatayeko team ko entry aafai firta. Refund JD wallet ma points ma aaucha.' },
  { id: 'tenpercent', q: '1 point matra|1point matra|10%|10 percent|kina 1 point|thorai matra aayo|full refund aayena|15 points firta|hamro 15 points|refund kam aayo|last moment withdraw',
    en: 'Withdrawing in the last 24 hours before the start returns only 10% of the entry (e.g. 15 → 1). Leaving 24h or more before gives the full entry back. If the event was then cancelled, a JD team member will check it.',
    ne: 'Start bhanda antim 24h ma withdraw garda entry ko 10% matra aaucha (15 bata 1). 24h agadi chhode pura firta. Pachhi event cancel bhayeko bhaye JD team le check garcha.', flag: true },
  { id: 'refundmissing', q: 'refund aayena|refund missing|refund pako chaina|refund kaha|refund bhayena|refund kina aayena',
    en: 'Open /wallet/ and look for a "Refund" line in the history first. If it isn\'t there, a JD team member will check: send your username, the event and a screenshot.',
    ne: 'Pahile /wallet/ history ma "Refund" line hera. Chaina bhane JD team le check garcha: username, kun event ra screenshot pathau.', flag: true },
  { id: 'balance', q: 'mero point kati|how many points|points kati cha|balance|my points|mero balance|kati point cha|wallet balance|point check',
    en: 'Your points balance is at the top of /wallet/ (tap the coin), with the full history below it.',
    ne: 'Points balance /wallet/ ko mathi (coin thich) ma cha, tala pura history.' },
  { id: 'deducted', q: 'point katyo|points deduct|kina katyo|why deducted|points ghatyo|point kam bhayo|deduct bhayo',
    en: 'Every change is listed in /wallet/ history with the reason (entry, challenge stake, waitlist place, effect, withdrawal). If one looks wrong, send a screenshot to support: +977 986-8813682.',
    ne: '/wallet/ history ma har point ko karan cha (entry, challenge, waitlist, effect, withdraw). Galat lagyo bhane screenshot support lai: +977 986-8813682.' },
  { id: 'effects', q: 'effect|effects|squad effect|top slot|top slots|effect kinne|effect kati|glow|effect le k huncha',
    en: 'Squad effects are a look for your squad and also give you the top slots in your events: Rs 2 one match, Rs 5 lite week, Rs 10 pro week, Rs 30 pro month. Bought with points from your ticket.',
    ne: 'Squad effect le team lai ramro dekhauchha ra event ma top slot pani dincha: Rs 2 ek match, Rs 5 lite week, Rs 10 pro week, Rs 30 pro month. Ticket bata points le kinna milcha.' },
  { id: 'pass', q: 'weekly pass|pass|weekly pro|pass kinne|pass kati',
    en: 'The Weekly Pass and Weekly Pro are switched off for now, so you don\'t need one. Free events take a free card or 15 points.',
    ne: 'Weekly Pass ra Weekly Pro ahile band cha, chahidaina. Free event ma free card wa 15 points.' },
  { id: 'ads', q: 'ads|ad herne|watch ads|ad|advertisement',
    en: 'Ads are off: there are no ads to watch for anything on JD Arena right now.',
    ne: 'Ads band cha: ahile JD Arena ma kei ko lagi pani ad hernu pardaina.' },

  // ── challenges ──
  { id: 'challenge', q: 'challenge|challenges|clash squad|cs|1v1|2v2|4v4|challenge k ho|cs khelne|cs challenge|custom cs|1v1 khelne',
    en: 'Challenges are 1v1 to 4v4 Clash Squad matches for JD points (18+). Both sides put in the same stake and the winner gets both minus a 1-point fee per player (20 each → 38). /challenges/',
    ne: 'Challenge bhaneko 1v1 dekhi 4v4 Clash Squad match JD points ko lagi (18+). Dubai le same points halcha, jitne le dubai paucha, player pichhe 1 point fee (20-20 → 38). /challenges/' },
  { id: 'chcreate', q: 'challenge kasari|create challenge|challenge banaune|challenge kasari khelne|challenge accept|how to challenge|challenge garne',
    en: 'Open /challenges/, tap Create, pick the size, stake and room settings (skills, gun attributes, rounds), and wait for someone to accept. You can cancel for a full refund before anyone accepts.',
    ne: '/challenges/ khol, Create thich, size, points ra room setting (skill, gun attribute, round) chhan, ani kasaile accept garna parkha. Accept nagarunjel cancel garda pura firta.' },
  { id: 'chresult', q: 'challenge haryo|lost challenge|haryo bhane|garyo vne k hunx|challenge jityo|we won|we lost|challenge result|challenge ma k huncha|haryo vane',
    en: 'After the match both captains tap We won / We lost. "We lost" pays the other side at once. Lose and your stake goes to the winner; win and you get both stakes minus the small fee.',
    ne: 'Match pachi dubai captain le We won / We lost thichcha. Haryo bhane timro points jitne lai jancha; jitye dubai ko points paucha (sano fee katera).' },
  { id: 'chdispute', q: 'both claim|dubai le jitye bhanyo|challenge dispute|opponent cheat challenge|challenge ma jhagada|wrong claim|challenge screenshot',
    en: 'If both sides claim the win, send your result screenshot in the challenge chat with the 📷 button and a JD mod decides. No decision in 24 hours = both stakes refunded.',
    ne: 'Dubai le jityo bhane challenge chat ma 📷 thichera result screenshot pathau, JD mod le decide garcha. 24 ghanta bhitra decide bhayena bhane dubai ko points firta.', flag: true },
  { id: 'cs_bo3', q: 'cs best of 3|clash squad best of 3|cs ma kati round|cs round|cs ma 2 jitne|cs win 2',
    en: 'In Clash Squad "best of 3" the first side to win 2 wins. In challenges the creator sets the number of rounds. (BR tournaments are different: all matches are played on points.)',
    ne: 'Clash Squad ko "best of 3" ma pahile 2 jitne jitcha. Challenge ma round creator le rakhcha. (BR tournament farak ho: sabai match khelincha, point basis.)' },
  { id: 'under18', q: 'under 18|i am 15|i am 16|i am 17|age|umar|18 bhanda sano|minor',
    en: 'Challenges are 18+ only. Under 18 you can still play tournaments, but not challenges.',
    ne: 'Challenge 18+ matra ho. 18 muni ko le tournament khelna milcha, challenge mildaina.' },

  // ── trust, safety and support ──
  { id: 'diamonds', q: 'free diamond|diamond|dia dinu|redeem code|redeem|free dj|diamond chahiyo|dimond|dract diamond|top up diamond|elite pass|free bundle|diamond milcha|diamond paincha',
    en: 'JD Arena doesn\'t give diamonds or redeem codes. You win JD points (prizes and challenges) that you can withdraw to eSewa.',
    ne: 'JD Arena le diamond wa redeem code dinna. Prize ra challenge bata JD points jitincha, jun eSewa ma withdraw garna milcha.' },
  { id: 'hack', q: 'hack|hacker|mod menu|panel|aimbot|headshot hack|cheat|hack dinu|hack kaha|auto headshot|injector|regedit',
    en: 'No hacks, panels or mod menus here: cheating gets a ban on the public Ban List. Play clean and win for real. 💪',
    ne: 'Hack, panel, mod menu ko kura nagara: cheat garne ban hunchha, Ban List ma naam aaucha. Clean khela, sachai jita. 💪' },
  { id: 'report', q: 'report|hacker report|cheater|cheat garyo|report garne|report kasari|teaming|someone cheated|zone pusher|rule todyo',
    en: 'Report it from the site with evidence (video or screenshots) and an admin reviews every report. Cheaters end up on the public Ban List.',
    ne: 'Site bata evidence (video wa screenshot) sanga report gara, admin le har report herchha. Cheater Ban List ma jancha.', flag: true },
  { id: 'banned', q: 'banned|mero account ban|why banned|ban kina|unban|ban hatau|ban appeal|ban bhayo',
    en: 'Bans are decided by the JD admin. A JD team member will look at your case: send your username and what happened.',
    ne: 'Ban JD admin le decide garcha. JD team le timro kura herchha: username ra k bhayo pathau.', flag: true },
  { id: 'scam', q: 'scam|fake|fraud|froud|jhut|thag|rigged|admin cheat|paisa khancha|fake app|real ho|trusted|bharosa',
    en: 'JD Arena is real: prizes are posted before you join and paid automatically into the wallet, results come from the official room, refunds show in your wallet history and cheaters go on the public Ban List.',
    ne: 'JD Arena real ho: prize join agadi nai lekheko huncha ra aafai wallet ma aaucha, result official room bata, refund wallet history ma dekhincha, cheater Ban List ma.' },
  { id: 'invite', q: 'invite|referral|refer|invite code|ref code|friend invite|invite garne|invite link|share code',
    en: 'Your invite code is your JD tag (profile > Invite friends). When a friend you invited saves their own Free Fire UID and plays their first event, you get 1 free entry card (30 days). Up to 3 friends. Never points.',
    ne: 'Timro invite code timro JD tag ho (profile > Invite friends). Timle invite gareko saathi le aafno Free Fire UID save garera pahilo event khelepachi timi 1 free card pauchau (30 din). 3 jana samma. Points hudaina.' },
  { id: 'support', q: 'support|contact|whatsapp number|phone number|helpline|customer care|number dinu|talk to admin|admin sanga kura|human|real person sanga|person sanga kura|mod sanga kura|call',
    en: 'JD customer support: call or WhatsApp +977 986-8813682. Send your username and a screenshot. Discord: discord.gg/dgvQTbNvVu',
    ne: 'JD customer support: call wa WhatsApp +977 986-8813682. Username ra screenshot pathau. Discord: discord.gg/dgvQTbNvVu' },
  { id: 'live', q: 'live|live stream|tiktok live|youtube live|live kaha|stream|live herne|live kaile|yt ma',
    en: 'Live streams are announced on TikTok (@ayer_fire) and in your alerts. Not every event is streamed.',
    ne: 'Live stream TikTok (@ayer_fire) ra alert ma announce huncha. Sabai event live hudaina.' },
  { id: 'rude', q: 'gaali|muji|randi|machikne|bhalu|fuck|bitch|idiot|stupid|bakwas|chor|chutiya',
    en: 'Let\'s keep it respectful 🙏 Tell me what went wrong and I\'ll help you sort it out.',
    ne: 'Ramro sanga kura garau na 🙏 K bigriyo bhana, ma help garchu.' },
  { id: 'abouttiktok', q: 'tiktok|tiktok id|ayer fire|ayer_fire|jd ko tiktok|follow kaslai|facebook|fb page',
    en: 'Follow JD on TikTok: @ayer_fire. New events, results and live streams are posted there.',
    ne: 'JD ko TikTok: @ayer_fire follow gara. Naya event, result ra live tyahi aaucha.' },

  // ── Free Fire and esports ──
  { id: 'improve', q: 'how to improve|pro kasari banne|tips|tips dinu|aim tips|headshot tips|kasari ramro khelne|skill badhaune|gameplay tips|how to win|booyah kasari|jitne tarika|pro banna',
    en: 'Quick tips: lock a sensitivity and drill it in training, play close-range fights with gloo walls, rotate early with the zone instead of fighting late, and talk with one shot-caller in your squad. Practise in Clash Squad challenges. /challenges/',
    ne: 'Tips: eutai sensitivity rakhera training ma practice gara, close fight ma gloo wall chalau, zone sanga chado rotate gara, squad ma eutai IGL le call garos. Clash Squad challenge ma practice gara. /challenges/' },
  { id: 'brstrategy', q: 'br strategy|rush or camp|camping|rush|rotation|zone strategy|landing|kaha land garne|drop|hot drop|tournament strategy',
    en: 'In points-based BR, survival matters as much as kills: land somewhere safe enough to loot, take fights you can win, rotate early with the zone and keep the squad alive for placement points. Top 3 placements with a few kills beat one early-kill frenzy.',
    ne: 'Point basis BR ma bachnu ra kill dubai jaruri: loot garna milne safe thau ma land, jitne fight matra lina, zone sanga chado rotate, squad lai bachaera placement point lina. Thorai kill sanga top 3 bhaye ekdam ramro.' },
  { id: 'sensi', q: 'sensitivity|sensi|best sensitivity|sensi setting|hud|control setting|dpi|graphics setting',
    en: 'There\'s no single best sensitivity: start around the default, raise General until you can turn 180° in one swipe, then fine-tune Red Dot/2x in training until your drag lands on the head. Stick with it for a week.',
    ne: 'Eutai best sensi hudaina: default bata suru, General badhau jaba samma ek swipe ma 180° ghumcha, ani training ma Red Dot/2x milau jaba drag head ma pugcha. Ek hapta tyahi rakha.' },
  { id: 'character', q: 'best character|character combo|skill combo|best combo|kun character|which character|character list|ray|alok|chrono|kelly|best skill',
    en: 'Combos change every update, so check the FF Guide for current characters and skills: jdesport.co.uk/ff/. Remember Orion, Sonia, Dimitri and Ryden are banned in JD tournaments.',
    ne: 'Har update ma combo pherincha, FF Guide ma hera: jdesport.co.uk/ff/. JD tournament ma Orion, Sonia, Dimitri ra Ryden ban cha.' },
  { id: 'gun', q: 'best gun|kun gun|which gun|gun combo|m1887|mp40|ump|ak|scar|best weapon|gun damage|sniper',
    en: 'Gun stats change each update, so check the in-game Armory or the FF Guide (jdesport.co.uk/ff/). In JD rooms gun attributes are OFF, so skins don\'t add stats.',
    ne: 'Gun ko stats update ma pherincha, in-game Armory wa FF Guide (jdesport.co.uk/ff/) hera. JD room ma gun attributes OFF huncha, skin le stats thapdaina.' },
  { id: 'phonelag', q: 'lag|lag huncha|phone lag|ping high|high ping|fps drop|game hang|network problem|lag kasari hataune|ping|game slow',
    en: 'For phone lag: close background apps, turn battery saver off and performance mode on, lower graphics to Smooth with high FPS, and use stable Wi-Fi. On PC/emulator, the JD Frag Engine helps. /optimizer/',
    ne: 'Phone lag: background app band gara, performance mode on, graphics Smooth + high FPS, stable Wi-Fi chalau. PC/emulator ma JD Frag Engine le help garcha. /optimizer/' },
  { id: 'optimizer', q: 'optimizer|frag engine|jd optimizer|pc boost|fps boost|emulator lag|pc lag|bluestacks lag|msi app player',
    en: 'JD Frag Engine is a Windows app that boosts FPS and cuts lag for Free Fire on emulators (MSI App Player, BlueStacks). It\'s account-safe and doesn\'t touch the game. /optimizer/',
    ne: 'JD Frag Engine Windows app ho jasle emulator (MSI, BlueStacks) ma Free Fire ko FPS badhaucha ra lag ghataucha. Account safe, game chhudaina. /optimizer/' },
  { id: 'esports', q: 'ffws|free fire world series|esports|free fire esports|pro league|nepal esports|ffnc|ff esports|professional team|tournament nepal',
    en: 'Pro Free Fire esports (like Garena\'s Free Fire World Series) uses the same idea as JD: placement + kill points over several matches, highest total wins. JD scrims are a good place to practise that format.',
    ne: 'Pro Free Fire esports (Garena ko Free Fire World Series jasto) ma pani JD jastai: dherai match ko placement + kill point, total dherai wala jitcha. JD scrim tyo format practice garna ramro thau ho.' },
  { id: 'igl', q: 'igl|in game leader|shot caller|team role|rusher|sniper role|support role|role kasari',
    en: 'A classic squad: one IGL (calls rotations), one or two rushers for close fights, a support with gloo walls and revives, and a sniper/anchor who covers. Agree roles before the match.',
    ne: 'Ramro squad: eutai IGL (rotation call), 1-2 rusher, gloo wall ra revive garne support, ra cover garne sniper. Match agadi role tai gara.' },
];

// ── matching ──
const SPELL: Record<string, string> = {
  xa: 'cha', chha: 'cha', 6: 'cha', xan: 'chan', hunxa: 'huncha', hunchha: 'huncha', hunx: 'huncha', vayo: 'bhayo', vako: 'bhako', vane: 'bhane', vne: 'bhane',
  vanxa: 'bhancha', kasri: 'kasari', ksri: 'kasari', ksari: 'kasari', hlo: 'hello', helo: 'hello', hlw: 'hello', hloo: 'hello', hellow: 'hello', hii: 'hi', hiii: 'hi', hy: 'hi',
  plz: 'please', pls: 'please', plzz: 'please', u: 'you', r: 'are', ur: 'your', tw: 'ta', ni: 'pani', nai: 'nai', aayena: 'aayena', aaena: 'aayena', ayena: 'aayena', aayana: 'aayena',
  kaile: 'kaile', kahile: 'kaile', kaha: 'kaha', kata: 'kaha', dinu: 'dinu', dinus: 'dinu', dinuna: 'dinu', dinun: 'dinu', garidinu: 'gardinu', gardinus: 'gardinu', tornament: 'tournament',
  turnament: 'tournament', tourament: 'tournament', tournment: 'tournament', tourney: 'tournament', reffund: 'refund', refun: 'refund', widraw: 'withdraw', withdrow: 'withdraw', withdrawl: 'withdraw',
  pasword: 'password', passward: 'password', dimond: 'diamond', diomand: 'diamond', daimand: 'diamond', daimond: 'diamond', points: 'point', pts: 'point', matches: 'match', cards: 'card', khelna: 'khelne', khelnu: 'khelne',
  thanku: 'thanks', thnx: 'thanks', thx: 'thanks', okk: 'ok', okey: 'ok', okay: 'ok', oky: 'ok', 'नमस्ते': 'namaste',
};
const STOP = new Set(['sir', 'dai', 'bro', 'vai', 'bhai', 'please', 'the', 'a', 'an', 'is', 'i', 'me', 'my', 'to', 'of', 'in', 'on', 'for', 'and', 'it', 'ma', 'ko', 'lai', 'le', 'ta', 'ni', 'pani', 'hai', 'na', 'n', 'ra', 'ki', 'yo', 'tyo', 'jd', 'zulu', 'hajur', 'mero', 'malai', 'can', 'do', 'what', 'how', 'why', 'k', 'ke', 'aba', 'ani', 'ho', 'hola', 'that', 'this', 'you', 'are', 'we', 'our', 'your']);
const norm = (s: string) => String(s || '').toLowerCase().normalize('NFKC').replace(/[’']/g, '').replace(/[^\p{L}\p{N}\p{Extended_Pictographic}ऀ-ॿ]+/gu, ' ')
  .trim().split(/\s+/).filter(Boolean).map((w) => SPELL[w] || w);
const tokens = (s: string) => { const all = [...new Set(norm(s))]; const t = all.filter((w) => !STOP.has(w)); return t.length ? t : all; };

interface Phrase { e: KBEntry; t: string[]; joined: string }
const PHRASES: Phrase[] = K.flatMap((e) => e.q.split('|').map((p) => { const t = tokens(p); return { e, t, joined: t.join(' ') }; }));
export const KB_SIZE = { topics: K.length, phrasings: PHRASES.length };

export interface KBHit { entry: KBEntry; score: number }
/** Topics that match a player message best, best first. score 1 = an exact known phrasing. */
export function kbMatch(message: string, limit = 3): KBHit[] {
  const q = tokens(message);
  if (!q.length) return [];
  const qs = new Set(q), joined = q.join(' ');
  const best = new Map<string, KBHit>();
  for (const p of PHRASES) {
    if (!p.t.length) continue;
    let score: number;
    if (p.joined === joined) score = 1;
    else {
      const hit = p.t.filter((w) => qs.has(w) || (w.length >= 5 && q.some((x) => x.length >= 5 && (x.startsWith(w) || w.startsWith(x))))).length;
      if (!hit) continue;
      score = 0.6 * (hit / p.t.length) + 0.4 * (hit / q.length);
      if (p.t.length === 1 && q.length > 3) score *= 0.6;   // one shared word in a long message is weak evidence
    }
    const prev = best.get(p.e.id);
    if (!prev || score > prev.score) best.set(p.e.id, { entry: p.e, score });
  }
  return [...best.values()].sort((a, b) => b.score - a.score).slice(0, limit);
}

/** 'dv' Devanagari, 'ne' romanized Nepali, 'en' English: from the player's own words. */
export function kbLang(text: string): 'dv' | 'ne' | 'en' {
  if (/[ऀ-ॿ]/.test(text)) return 'dv';
  return /\b(cha|chha|xa|xaina|chaina|huncha|hunxa|hunchha|kasari|kasri|ksri|kaile|kahile|kaha|kati|garne|garnu|gardinu|dinu|bhayo|vayo|bhayena|vayena|aayena|ayena|mero|malai|hamro|tapai|timi|hajur|ho|haina|bro|dai|vai|bhane|vane|paincha|milcha|khelne|khelna|sakchu|parcha|garyo|ramro|ani|ta|ni|pani)\b/i.test(text) ? 'ne' : 'en';
}

/**
 * The language for this reply, from the player's own messages (newest first): one short English
 * word like "rules" follows the language they were already using, never the app setting.
 * Returns a line for the system prompt.
 */
export function kbReplyLang(playerMsgs: string[], fallback: 'ne' | 'en'): string {
  const name = { dv: 'Nepali in Devanagari script', ne: 'romanized Nepali (Latin letters, like "kasari join garne")', en: 'English' };
  let guess: 'dv' | 'ne' | 'en' | null = null;
  for (const m of [...playerMsgs].reverse()) {
    const t = String(m || '').trim();
    if (!/\p{L}/u.test(t)) continue;
    const l = kbLang(t);
    if (l !== 'en' || t.split(/\s+/).length >= 3) { guess = l; break; }
    guess = guess || 'en';
  }
  return `\n\nLANGUAGE FOR THIS REPLY: ${name[guess || (fallback === 'ne' ? 'dv' : 'en')]}. Use it even if earlier replies used another language.`;
}

const pick = (v: string | string[] | undefined) => !v ? '' : Array.isArray(v) ? v[Math.floor(Math.random() * v.length)] : v;
export function kbAnswer(e: KBEntry, lang: 'dv' | 'ne' | 'en'): string {
  return pick(lang === 'dv' ? (e.dv || e.ne) : lang === 'ne' ? e.ne : e.en);
}

/** An instant reply for pure small talk ("hlo", "thanks", "ok 👍"), or null when the message needs a real answer. */
export function kbSmallTalk(message: string): string | null {
  const q = tokens(message);
  if (q.length > 4) return null;
  const [top] = kbMatch(message, 1);
  if (!top || !top.entry.small || top.score < 0.85) return null;
  return kbAnswer(top.entry, kbLang(message));
}

/** Checked answers for the AI prompt: the topics this message is about, in English (the AI writes the reply language). */
export function kbPrompt(message: string): string {
  const hits = kbMatch(message, 3).filter((h) => h.score >= 0.4 && !h.entry.small);
  if (!hits.length) return '';
  return '\n\nJD ANSWER BOOK, checked answers to the topic of the player\'s LAST message (use the facts, write it in your own words and in the player\'s language; the live data and the account note win for times, seats and their own points):\n' +
    hits.map((h) => `- ${h.entry.id}: ${pick(h.entry.en)}`).join('\n');
}

/** When every AI model failed: the best checked answer, or null when nothing matches well enough. */
export function kbFallback(message: string): { text: string; flag: boolean } | null {
  const [top] = kbMatch(message, 1);
  if (!top || top.score < 0.45) return null;
  return { text: kbAnswer(top.entry, kbLang(message)), flag: !!top.entry.flag };
}
