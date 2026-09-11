import 'package:flutter/material.dart';
import 'map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RouteFlowApp());
}

/// Root widget of the application.
class RouteFlowApp extends StatelessWidget {
  const RouteFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RouteFlow Driver Navigation',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const MapScreen(),
    );
  }
}
