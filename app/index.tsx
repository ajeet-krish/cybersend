import Constants from 'expo-constants';
import { StyleSheet, Text, View } from 'react-native';

import { readBuildVariant } from '@/src/app/flags';

// Phase 0 home screen: proves the route tree boots and reports the active build variant.
export default function HomeScreen() {
  const variant = readBuildVariant(Constants.expoConfig?.extra);
  return (
    <View style={styles.container}>
      <Text style={styles.title}>CyberSend</Text>
      <Text style={styles.variant}>Build variant: {variant}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#ffffff',
  },
  title: {
    fontSize: 28,
    fontWeight: '600',
  },
  variant: {
    marginTop: 8,
    fontSize: 16,
    color: '#444444',
  },
});
