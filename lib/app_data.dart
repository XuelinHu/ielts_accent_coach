enum AccentProfile {
  british('英式', 'British', 'en-GB', 'RP / Modern British'),
  american('美式', 'American', 'en-US', 'General American'),
  australian('澳式', 'Australian', 'en-AU', 'General Australian');

  const AccentProfile(this.label, this.englishLabel, this.locale, this.detail);

  final String label;
  final String englishLabel;
  final String locale;
  final String detail;
}

class PracticeLine {
  const PracticeLine({
    required this.topic,
    required this.level,
    required this.text,
    required this.focus,
    required this.tip,
    required this.accent,
  });

  final String topic;
  final String level;
  final String text;
  final String focus;
  final String tip;
  final AccentProfile accent;
}

const practiceLines = <PracticeLine>[
  PracticeLine(
    topic: 'Part 1 · Hometown',
    level: '基础',
    text:
        'I grew up in a quiet coastal town, but it has changed considerably in recent years.',
    focus: '弱读与连读',
    tip: '把 “but it has” 连成一个平滑的语流，重读 coastal、changed 和 recent。',
    accent: AccentProfile.british,
  ),
  PracticeLine(
    topic: 'Part 2 · Experience',
    level: '进阶',
    text:
        'What made the experience memorable was not the destination, but the people I met along the way.',
    focus: '句子重音',
    tip: '用重音形成对比：not the destination, but the people。',
    accent: AccentProfile.british,
  ),
  PracticeLine(
    topic: 'Part 3 · Education',
    level: '挑战',
    text:
        'Although online learning offers greater flexibility, it cannot entirely replace face-to-face discussion.',
    focus: '语调与停顿',
    tip: '在 flexibility 后短暂停顿，前半句微升，结论部分自然下降。',
    accent: AccentProfile.british,
  ),
  PracticeLine(
    topic: 'Part 1 · Daily life',
    level: '基础',
    text:
        'I usually grab a cup of coffee before heading to work in the morning.',
    focus: '闪音与节奏',
    tip: '美式口音中 heading to 可自然连读，coffee 的首音节更突出。',
    accent: AccentProfile.american,
  ),
  PracticeLine(
    topic: 'Part 2 · Technology',
    level: '进阶',
    text:
        'The device was surprisingly practical, especially when I needed to organize a complicated schedule.',
    focus: '清晰度',
    tip: '不要吞掉 surprisingly 和 especially 的中间音节。',
    accent: AccentProfile.american,
  ),
  PracticeLine(
    topic: 'Part 3 · Environment',
    level: '挑战',
    text:
        'Governments should encourage practical alternatives rather than simply restricting individual choices.',
    focus: '辅音收尾',
    tip: '读清 governments、alternatives 和 choices 的尾辅音。',
    accent: AccentProfile.american,
  ),
  PracticeLine(
    topic: 'Part 1 · Weekends',
    level: '基础',
    text:
        'On the weekend, I often catch up with friends or spend some time outdoors.',
    focus: '元音与节奏',
    tip: '澳式英语中 today、mate 一类双元音更集中，但不要刻意夸张。',
    accent: AccentProfile.australian,
  ),
  PracticeLine(
    topic: 'Part 2 · Journey',
    level: '进阶',
    text:
        'We drove through the countryside and stopped at a small café near the harbour.',
    focus: '非卷舌音',
    tip: 'harbour 末尾的 r 通常不发音，除非后面紧接元音。',
    accent: AccentProfile.australian,
  ),
  PracticeLine(
    topic: 'Part 3 · Cities',
    level: '挑战',
    text:
        'Public transport needs to be both reliable and affordable if cities are to remain liveable.',
    focus: '自然语流',
    tip: '保持 reliable and affordable 连贯，避免逐词朗读。',
    accent: AccentProfile.australian,
  ),
];
