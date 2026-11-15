import 'package:flutter/material.dart';
import 'theme.dart';
import 'widgets/mc_shell.dart';

class SolNavApp extends StatelessWidget {
  const SolNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SolNav',
      debugShowCheckedModeBanner: false,
      theme: MC.theme(),
      // Stops a phone's "large font" setting from breaking the layout.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(maxScaleFactor: 1.15),
          ),
          child: child!,
        );
      },
      home: const McShell(),
    );
  }
}
