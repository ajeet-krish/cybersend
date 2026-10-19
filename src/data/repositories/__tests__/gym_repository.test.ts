// Gym repository tests (US-8): create, rename, archive visibility, duplicate names, walls.

import { create_test_database } from '../../db/testing';
import { DomainValidationError } from '../../../domain/errors';

describe('GymRepository', () => {
  test('creates a gym and lists it as active', async () => {
    const { repos } = await create_test_database();
    const gym = await repos.gyms.create({ name: 'Boulder Garden' });

    expect(gym.name).toBe('Boulder Garden');
    expect(gym.isActive).toBe(true);
    const listed = await repos.gyms.list();
    expect(listed.map((candidate) => candidate.id)).toEqual([gym.id]);
    expect(await repos.gyms.get(gym.id)).toEqual(gym);
  });

  test('rejects an empty name', async () => {
    const { repos } = await create_test_database();
    await expect(repos.gyms.create({ name: '   ' })).rejects.toThrow(DomainValidationError);
  });

  test('allows duplicate names, disambiguated by id (US-8.3)', async () => {
    const { repos } = await create_test_database();
    const first = await repos.gyms.create({ name: 'Momentum' });
    const second = await repos.gyms.create({ name: 'Momentum' });
    expect(first.id).not.toBe(second.id);
    expect(await repos.gyms.list()).toHaveLength(2);
  });

  test('renames a gym and rejects unknown ids', async () => {
    const { repos } = await create_test_database();
    const gym = await repos.gyms.create({ name: 'Old name' });
    const renamed = await repos.gyms.rename(gym.id, 'New name');
    expect(renamed.name).toBe('New name');
    expect(renamed.updatedAt >= gym.updatedAt).toBe(true);
    await expect(repos.gyms.rename('missing', 'x')).rejects.toThrow('Gym not found');
  });

  test('archived gyms are hidden from the default list but visible with include_archived (US-8.4)', async () => {
    const { repos } = await create_test_database();
    const gym = await repos.gyms.create({ name: 'Seasonal' });
    await repos.gyms.archive(gym.id);

    expect(await repos.gyms.list()).toEqual([]);
    const all = await repos.gyms.list(true);
    expect(all.map((candidate) => candidate.id)).toEqual([gym.id]);
    expect(all[0]?.isActive).toBe(false);

    await repos.gyms.unarchive(gym.id);
    expect(await repos.gyms.list()).toHaveLength(1);
  });

  test('walls belong to the gym aggregate and require a valid gym (FK enforced)', async () => {
    const { repos } = await create_test_database();
    const gym = await repos.gyms.create({ name: 'Wall Town' });
    const wall = await repos.gyms.createWall({ gymId: gym.id, name: 'Slab', angleDeg: 20 });

    expect(wall.angleDeg).toBe(20);
    const walls = await repos.gyms.listWalls(gym.id);
    expect(walls.map((candidate) => candidate.id)).toEqual([wall.id]);

    await expect(repos.gyms.createWall({ gymId: 'missing', name: 'x' })).rejects.toThrow();
    await expect(repos.gyms.createWall({ gymId: gym.id, angleDeg: 120 })).rejects.toThrow('between 0 and 90');

    await repos.gyms.setWallActive(wall.id, false);
    expect(await repos.gyms.listWalls(gym.id)).toEqual([]);
    expect(await repos.gyms.listWalls(gym.id, true)).toHaveLength(1);
  });
});
