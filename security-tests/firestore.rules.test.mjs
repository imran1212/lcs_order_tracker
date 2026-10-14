import fs from 'node:fs';
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  updateDoc,
  where,
  writeBatch,
} from 'firebase/firestore';

const projectId = 'demo-lcs-tracker';
const rules = fs.readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8');
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: { rules },
  });

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users/admin-1'), {
      name: 'Admin', role: 'admin', active: true,
    });
    await setDoc(doc(db, 'users/worker-a'), {
      name: 'Worker A', role: 'worker', active: true,
    });
    await setDoc(doc(db, 'users/worker-b'), {
      name: 'Worker B', role: 'worker', active: true,
    });
    await setDoc(doc(db, 'users/worker-disabled'), {
      name: 'Disabled Worker', role: 'worker', active: false,
    });
    await setDoc(doc(db, 'orders/order-a'), {
      cn: 'CN-A-1001', workerUid: 'worker-a', status: 'In Transit',
    });
    await setDoc(doc(db, 'orders/order-b'), {
      cn: 'CN-B-2002', workerUid: 'worker-b', status: 'Delivered',
    });
    await setDoc(doc(db, 'syncJobs/job-a'), {
      ownerUid: 'worker-a', status: 'running',
    });
    await setDoc(doc(db, 'syncJobs/job-b'), {
      ownerUid: 'worker-b', status: 'running',
    });
  });
});

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

test('worker can read own profile and assigned order', async () => {
  const db = testEnv.authenticatedContext('worker-a').firestore();
  await assertSucceeds(getDoc(doc(db, 'users/worker-a')));
  await assertSucceeds(getDoc(doc(db, 'orders/order-a')));
});

test('worker cannot read another worker order or query outside assignment', async () => {
  const db = testEnv.authenticatedContext('worker-a').firestore();
  await assertFails(getDoc(doc(db, 'orders/order-b')));
  await assertSucceeds(getDocs(query(
    collection(db, 'orders'),
    where('workerUid', '==', 'worker-a'),
  )));
});

test('worker cannot list user profiles, reassign, or delete an order', async () => {
  const db = testEnv.authenticatedContext('worker-a').firestore();
  await assertFails(getDocs(collection(db, 'users')));
  await assertFails(updateDoc(doc(db, 'orders/order-a'), {
    workerUid: 'worker-b',
  }));
  await assertFails(deleteDoc(doc(db, 'orders/order-a')));
});

test('admin can read organization orders and list worker profiles', async () => {
  const db = testEnv.authenticatedContext('admin-1').firestore();
  await assertSucceeds(getDoc(doc(db, 'orders/order-b')));
  await assertSucceeds(getDocs(collection(db, 'users')));
});

test('disabled worker can read own profile but cannot access orders', async () => {
  const db = testEnv.authenticatedContext('worker-disabled').firestore();
  await assertSucceeds(getDoc(doc(db, 'users/worker-disabled')));
  await assertFails(getDoc(doc(db, 'orders/order-a')));
});

test('worker can create an order and its initial history atomically', async () => {
  const db = testEnv.authenticatedContext('worker-a').firestore();
  const batch = writeBatch(db);
  batch.set(doc(db, 'orders/order-new'), {
    cn: 'CN-A-NEW', workerUid: 'worker-a', status: 'Pending API Sync',
  });
  batch.set(doc(db, 'orders/order-new/lcsStatusHistory/created'), {
    status: 'Pending API Sync', source: 'order_created',
  });
  await assertSucceeds(batch.commit());
});

test('worker cannot create an order assigned to another worker', async () => {
  const db = testEnv.authenticatedContext('worker-a').firestore();
  await assertFails(setDoc(doc(db, 'orders/forbidden'), {
    cn: 'CN-FORBIDDEN', workerUid: 'worker-b', status: 'Pending',
  }));
});

test('worker can create child sync items only under their own job', async () => {
  const db = testEnv.authenticatedContext('worker-a').firestore();
  await assertSucceeds(setDoc(doc(db, 'syncJobs/job-a/items/item-a'), {
    cn: 'CN-A-1001', status: 'pending',
  }));
  await assertFails(setDoc(doc(db, 'syncJobs/job-b/items/item-b'), {
    cn: 'CN-B-2002', status: 'pending',
  }));
});

test('unauthenticated clients cannot read orders', async () => {
  const db = testEnv.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(db, 'orders/order-a')));
});
