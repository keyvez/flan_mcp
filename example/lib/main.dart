import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:flan_flutter/flan_flutter.dart';

void main() {
  FlanBinding.ensureInitialized();

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: const ColorScheme(
          brightness: Brightness.light,
          primary: Colors.black,
          onPrimary: Colors.white,
          secondary: Colors.black54,
          onSecondary: Colors.white,
          error: Colors.black,
          onError: Colors.white,
          surface: Colors.white,
          onSurface: Colors.black,
        ),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _logger = Logger('MyHomePage');

  int _counter = 0;
  int _direction = 1; // 1 = up (increment), -1 = down (decrement)

  void _incrementCounter() {
    _logger.info('Incrementing counter, from $_counter');
    setState(() {
      _direction = 1;
      _counter++;
    });
  }

  void _decrementCounter() {
    _logger.info('Decrementing counter, from $_counter');
    setState(() {
      _direction = -1;
      _counter--;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowUp): _incrementCounter,
        const SingleActivator(LogicalKeyboardKey.arrowDown): _decrementCounter,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: .center,
          children: [
            Text(
              'You have pushed the button this many times:',
              style: TextStyle(
                fontFamily: 'Georgia',
                fontSize: 28,
              ),
            ),
            ClipRect(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) {
                  final isIncoming = child.key == ValueKey<int>(_counter);
                  // Tape/odometer effect: both numbers slide together.
                  // AnimatedSwitcher runs animation 0→1 for incoming,
                  // and 1→0 (reverse) for outgoing.
                  //
                  // Increment (_direction=1): tape moves upward
                  //   - incoming: begins below (+1), slides to center (0)
                  //   - outgoing: animation reverses, so Tween(+1→0)
                  //     plays as 0→+1, but we want it to go 0→-1 (up).
                  //     So outgoing uses Tween(-1→0), reversed = 0→-1.
                  final tween = isIncoming
                      ? Tween<Offset>(
                          begin: Offset(0, _direction.toDouble()),
                          end: Offset.zero,
                        )
                      : Tween<Offset>(
                          begin: Offset(0, -_direction.toDouble()),
                          end: Offset.zero,
                        );
                  final curvedAnimation = CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeInOut,
                  );
                  // Color transition: incoming fades from grey to black,
                  // outgoing fades from black to grey.
                  final colorTween = isIncoming
                      ? ColorTween(
                          begin: Colors.grey,
                          end: Colors.black,
                        )
                      : ColorTween(
                          begin: Colors.grey,
                          end: Colors.black,
                        );
                  return SlideTransition(
                    position: tween.animate(curvedAnimation),
                    child: AnimatedBuilder(
                      animation: curvedAnimation,
                      builder: (context, child) {
                        return DefaultTextStyle.merge(
                          style: TextStyle(
                            color: colorTween.evaluate(curvedAnimation),
                          ),
                          child: child!,
                        );
                      },
                      child: child,
                    ),
                  );
                },
                child: Text(
                  '$_counter',
                  key: ValueKey<int>(_counter),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontSize: (Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.fontSize ??
                                28) *
                            4,
                      ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FloatingActionButton(
              onPressed: _incrementCounter,
              tooltip: 'Increment',
              child: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    )),
    );
  }
}
