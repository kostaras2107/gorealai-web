// Μη-web πλατφόρμες (Android/iOS) — δεν υποστηρίζουν iframe embed του TikTok
// μέσω αυτού του μηχανισμού. Επιστρέφει κενό widget· ο καλών δείχνει fallback.
import 'package:flutter/material.dart';

Widget buildTikTokEmbed(String videoId) => const SizedBox.shrink();
