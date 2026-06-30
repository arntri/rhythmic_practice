import 'package:flutter/material.dart';

import '../metronome/metronome_engine.dart';
import '../metronome/metronome_ring.dart';

/// A test/playground screen for the metronome engine (brief build-order step 2).
/// Lets us start/stop, change tempo, and toggle each sensory channel. The real
/// practice screens will reuse the same [MetronomeEngine] later.
class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({super.key});

  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

// SingleTickerProviderStateMixin gives us the `vsync` the engine's Ticker needs.
class _MetronomeScreenState extends State<MetronomeScreen>
    with SingleTickerProviderStateMixin {
  late final MetronomeEngine _engine;
  int _bpm = 60;

  @override
  void initState() {
    super.initState();
    _engine = MetronomeEngine(vsync: this, bpm: _bpm);
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  void _toggleRunning() {
    setState(() {
      if (_engine.isRunning) {
        _engine.stop();
      } else {
        _engine.start();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Step 2 — Metronome')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            // Left: the pulsing ring.
            Expanded(
              child: MetronomeRing(
                phase: _engine.phase,
                enabled: _engine.visualEnabled,
              ),
            ),
            const SizedBox(width: 24),
            // Right: controls.
            SizedBox(
              width: 320,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: _toggleRunning,
                    icon: Icon(_engine.isRunning ? Icons.stop : Icons.play_arrow),
                    label: Text(_engine.isRunning ? 'Stop' : 'Start'),
                  ),
                  const SizedBox(height: 24),
                  Text('Tempo: $_bpm BPM',
                      style: Theme.of(context).textTheme.titleMedium),
                  Slider(
                    value: _bpm.toDouble(),
                    min: 40,
                    max: 120,
                    divisions: 80,
                    label: '$_bpm',
                    onChanged: (v) {
                      setState(() {
                        _bpm = v.round();
                        _engine.setBpm(_bpm);
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  // Each channel independently switchable (brief §4).
                  SwitchListTile(
                    title: const Text('Sound'),
                    subtitle: const Text('verify on a real device'),
                    value: _engine.soundEnabled,
                    onChanged: (v) => setState(() => _engine.soundEnabled = v),
                  ),
                  SwitchListTile(
                    title: const Text('Visual'),
                    value: _engine.visualEnabled,
                    onChanged: (v) => setState(() => _engine.visualEnabled = v),
                  ),
                  SwitchListTile(
                    title: const Text('Haptic'),
                    subtitle: const Text('verify on a real device'),
                    value: _engine.hapticEnabled,
                    onChanged: (v) => setState(() => _engine.hapticEnabled = v),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
