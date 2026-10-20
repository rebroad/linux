// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) 2013 Facebook.  All rights reserved.
 */

#include <linux/types.h>
#include "btrfs-tests.h"
#include "../ctree.h"
#include "../transaction.h"
#include "../disk-io.h"
#include "../qgroup.h"
#include "../backref.h"
#include "../fs.h"
#include "../accessors.h"

static int insert_normal_tree_ref(struct btrfs_root *root, u64 bytenr,
				  u64 num_bytes, u64 parent, u64 root_objectid)
{
	struct btrfs_trans_handle trans;
	struct btrfs_extent_item *item;
	struct btrfs_extent_inline_ref *iref;
	struct btrfs_tree_block_info *block_info;
	BTRFS_PATH_AUTO_FREE(path);
	struct extent_buffer *leaf;
	struct btrfs_key ins;
	u32 size = sizeof(*item) + sizeof(*iref) + sizeof(*block_info);
	int ret;

	btrfs_init_dummy_trans(&trans, NULL);

	ins.objectid = bytenr;
	ins.type = BTRFS_EXTENT_ITEM_KEY;
	ins.offset = num_bytes;

	path = btrfs_alloc_path();
	if (!path) {
		test_std_err(TEST_ALLOC_ROOT);
		return -ENOMEM;
	}

	ret = btrfs_insert_empty_item(&trans, root, path, &ins, size);
	if (ret) {
		test_err("couldn't insert ref %d", ret);
		return ret;
	}

	leaf = path->nodes[0];
	item = btrfs_item_ptr(leaf, path->slots[0], struct btrfs_extent_item);
	btrfs_set_extent_refs(leaf, item, 1);
	btrfs_set_extent_generation(leaf, item, 1);
	btrfs_set_extent_flags(leaf, item, BTRFS_EXTENT_FLAG_TREE_BLOCK);
	block_info = (struct btrfs_tree_block_info *)(item + 1);
	btrfs_set_tree_block_level(leaf, block_info, 0);
	iref = (struct btrfs_extent_inline_ref *)(block_info + 1);
	if (parent > 0) {
		btrfs_set_extent_inline_ref_type(leaf, iref,
						 BTRFS_SHARED_BLOCK_REF_KEY);
		btrfs_set_extent_inline_ref_offset(leaf, iref, parent);
	} else {
		btrfs_set_extent_inline_ref_type(leaf, iref, BTRFS_TREE_BLOCK_REF_KEY);
		btrfs_set_extent_inline_ref_offset(leaf, iref, root_objectid);
	}
	return 0;
}

static int add_tree_ref(struct btrfs_root *root, u64 bytenr, u64 num_bytes,
			u64 parent, u64 root_objectid)
{
	struct btrfs_trans_handle trans;
	struct btrfs_extent_item *item;
	BTRFS_PATH_AUTO_FREE(path);
	struct btrfs_key key;
	u64 refs;
	int ret;

	btrfs_init_dummy_trans(&trans, NULL);

	key.objectid = bytenr;
	key.type = BTRFS_EXTENT_ITEM_KEY;
	key.offset = num_bytes;

	path = btrfs_alloc_path();
	if (!path) {
		test_std_err(TEST_ALLOC_ROOT);
		return -ENOMEM;
	}

	ret = btrfs_search_slot(&trans, root, &key, path, 0, 1);
	if (ret) {
		test_err("couldn't find extent ref");
		return ret;
	}

	item = btrfs_item_ptr(path->nodes[0], path->slots[0],
			      struct btrfs_extent_item);
	refs = btrfs_extent_refs(path->nodes[0], item);
	btrfs_set_extent_refs(path->nodes[0], item, refs + 1);
	btrfs_release_path(path);

	key.objectid = bytenr;
	if (parent) {
		key.type = BTRFS_SHARED_BLOCK_REF_KEY;
		key.offset = parent;
	} else {
		key.type = BTRFS_TREE_BLOCK_REF_KEY;
		key.offset = root_objectid;
	}

	ret = btrfs_insert_empty_item(&trans, root, path, &key, 0);
	if (ret)
		test_err("failed to insert backref");
	return ret;
}

static int remove_extent_item(struct btrfs_root *root, u64 bytenr,
			      u64 num_bytes)
{
	struct btrfs_trans_handle trans;
	struct btrfs_key key;
	BTRFS_PATH_AUTO_FREE(path);
	int ret;

	btrfs_init_dummy_trans(&trans, NULL);

	key.objectid = bytenr;
	key.type = BTRFS_EXTENT_ITEM_KEY;
	key.offset = num_bytes;

	path = btrfs_alloc_path();
	if (!path) {
		test_std_err(TEST_ALLOC_ROOT);
		return -ENOMEM;
	}

	ret = btrfs_search_slot(&trans, root, &key, path, -1, 1);
	if (ret) {
		test_err("didn't find our key %d", ret);
		return ret;
	}
	btrfs_del_item(&trans, root, path);
	return 0;
}

static int remove_extent_ref(struct btrfs_root *root, u64 bytenr,
			     u64 num_bytes, u64 parent, u64 root_objectid)
{
	struct btrfs_trans_handle trans;
	struct btrfs_extent_item *item;
	BTRFS_PATH_AUTO_FREE(path);
	struct btrfs_key key;
	u64 refs;
	int ret;

	btrfs_init_dummy_trans(&trans, NULL);

	key.objectid = bytenr;
	key.type = BTRFS_EXTENT_ITEM_KEY;
	key.offset = num_bytes;

	path = btrfs_alloc_path();
	if (!path) {
		test_std_err(TEST_ALLOC_ROOT);
		return -ENOMEM;
	}

	ret = btrfs_search_slot(&trans, root, &key, path, 0, 1);
	if (ret) {
		test_err("couldn't find extent ref");
		return ret;
	}

	item = btrfs_item_ptr(path->nodes[0], path->slots[0],
			      struct btrfs_extent_item);
	refs = btrfs_extent_refs(path->nodes[0], item);
	btrfs_set_extent_refs(path->nodes[0], item, refs - 1);
	btrfs_release_path(path);

	key.objectid = bytenr;
	if (parent) {
		key.type = BTRFS_SHARED_BLOCK_REF_KEY;
		key.offset = parent;
	} else {
		key.type = BTRFS_TREE_BLOCK_REF_KEY;
		key.offset = root_objectid;
	}

	ret = btrfs_search_slot(&trans, root, &key, path, -1, 1);
	if (ret) {
		test_err("couldn't find backref %d", ret);
		return ret;
	}
	btrfs_del_item(&trans, root, path);
	return ret;
}

static int test_no_shared_qgroup(struct btrfs_root *root,
		u32 sectorsize, u32 nodesize)
{
	struct btrfs_backref_walk_ctx ctx = { 0 };
	struct btrfs_trans_handle trans;
	struct btrfs_fs_info *fs_info = root->fs_info;
	struct ulist *old_roots = NULL;
	struct ulist *new_roots = NULL;
	int ret;

	btrfs_init_dummy_trans(&trans, fs_info);

	test_msg("running qgroup add/remove tests");
	ret = btrfs_create_qgroup(&trans, BTRFS_FS_TREE_OBJECTID);
	if (ret) {
		test_err("couldn't create a qgroup %d", ret);
		return ret;
	}

	ctx.bytenr = nodesize;
	ctx.trans = &trans;
	ctx.fs_info = fs_info;

	/*
	 * Since the test trans doesn't have the complicated delayed refs,
	 * we can only call btrfs_qgroup_account_extent() directly to test
	 * quota.
	 */
	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	old_roots = ctx.roots;
	ctx.roots = NULL;

	ret = insert_normal_tree_ref(root, nodesize, nodesize, 0,
				BTRFS_FS_TREE_OBJECTID);
	if (ret) {
		ulist_free(old_roots);
		return ret;
	}

	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		ulist_free(old_roots);
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	new_roots = ctx.roots;
	ctx.roots = NULL;

	ret = btrfs_qgroup_account_extent(&trans, nodesize, nodesize, old_roots,
					  new_roots);
	if (ret) {
		test_err("couldn't account space for a qgroup %d", ret);
		return ret;
	}

	/* btrfs_qgroup_account_extent() always frees the ulists passed to it. */
	old_roots = NULL;
	new_roots = NULL;

	if (btrfs_verify_qgroup_counts(fs_info, BTRFS_FS_TREE_OBJECTID,
				nodesize, nodesize)) {
		test_err("qgroup counts didn't match expected values");
		return -EINVAL;
	}

	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	old_roots = ctx.roots;
	ctx.roots = NULL;

	ret = remove_extent_item(root, nodesize, nodesize);
	if (ret) {
		ulist_free(old_roots);
		return -EINVAL;
	}

	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		ulist_free(old_roots);
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	new_roots = ctx.roots;
	ctx.roots = NULL;

	ret = btrfs_qgroup_account_extent(&trans, nodesize, nodesize, old_roots,
					  new_roots);
	if (ret) {
		test_err("couldn't account space for a qgroup %d", ret);
		return -EINVAL;
	}

	if (btrfs_verify_qgroup_counts(fs_info, BTRFS_FS_TREE_OBJECTID, 0, 0)) {
		test_err("qgroup counts didn't match expected values");
		return -EINVAL;
	}

	return 0;
}

/*
 * Add a ref for two different roots to make sure the shared value comes out
 * right, also remove one of the roots and make sure the exclusive count is
 * adjusted properly.
 */
static int test_multiple_refs(struct btrfs_root *root,
		u32 sectorsize, u32 nodesize)
{
	struct btrfs_backref_walk_ctx ctx = { 0 };
	struct btrfs_trans_handle trans;
	struct btrfs_fs_info *fs_info = root->fs_info;
	struct ulist *old_roots = NULL;
	struct ulist *new_roots = NULL;
	int ret;

	btrfs_init_dummy_trans(&trans, fs_info);

	test_msg("running qgroup multiple refs test");

	/*
	 * We have BTRFS_FS_TREE_OBJECTID created already from the
	 * previous test.
	 */
	ret = btrfs_create_qgroup(&trans, BTRFS_FIRST_FREE_OBJECTID);
	if (ret) {
		test_err("couldn't create a qgroup %d", ret);
		return ret;
	}

	ctx.bytenr = nodesize;
	ctx.trans = &trans;
	ctx.fs_info = fs_info;

	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	old_roots = ctx.roots;
	ctx.roots = NULL;

	ret = insert_normal_tree_ref(root, nodesize, nodesize, 0,
				BTRFS_FS_TREE_OBJECTID);
	if (ret) {
		ulist_free(old_roots);
		return ret;
	}

	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		ulist_free(old_roots);
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	new_roots = ctx.roots;
	ctx.roots = NULL;

	ret = btrfs_qgroup_account_extent(&trans, nodesize, nodesize, old_roots,
					  new_roots);
	if (ret) {
		test_err("couldn't account space for a qgroup %d", ret);
		return ret;
	}

	if (btrfs_verify_qgroup_counts(fs_info, BTRFS_FS_TREE_OBJECTID,
				       nodesize, nodesize)) {
		test_err("qgroup counts didn't match expected values");
		return -EINVAL;
	}

	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	old_roots = ctx.roots;
	ctx.roots = NULL;

	ret = add_tree_ref(root, nodesize, nodesize, 0,
			BTRFS_FIRST_FREE_OBJECTID);
	if (ret) {
		ulist_free(old_roots);
		return ret;
	}

	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		ulist_free(old_roots);
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	new_roots = ctx.roots;
	ctx.roots = NULL;

	ret = btrfs_qgroup_account_extent(&trans, nodesize, nodesize, old_roots,
					  new_roots);
	if (ret) {
		test_err("couldn't account space for a qgroup %d", ret);
		return ret;
	}

	if (btrfs_verify_qgroup_counts(fs_info, BTRFS_FS_TREE_OBJECTID,
					nodesize, 0)) {
		test_err("qgroup counts didn't match expected values");
		return -EINVAL;
	}

	if (btrfs_verify_qgroup_counts(fs_info, BTRFS_FIRST_FREE_OBJECTID,
					nodesize, 0)) {
		test_err("qgroup counts didn't match expected values");
		return -EINVAL;
	}

	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	old_roots = ctx.roots;
	ctx.roots = NULL;

	ret = remove_extent_ref(root, nodesize, nodesize, 0,
				BTRFS_FIRST_FREE_OBJECTID);
	if (ret) {
		ulist_free(old_roots);
		return ret;
	}

	ret = btrfs_find_all_roots(&ctx, false);
	if (ret) {
		ulist_free(old_roots);
		test_err("couldn't find old roots: %d", ret);
		return ret;
	}
	new_roots = ctx.roots;
	ctx.roots = NULL;

	ret = btrfs_qgroup_account_extent(&trans, nodesize, nodesize, old_roots,
					  new_roots);
	if (ret) {
		test_err("couldn't account space for a qgroup %d", ret);
		return ret;
	}

	if (btrfs_verify_qgroup_counts(fs_info, BTRFS_FIRST_FREE_OBJECTID,
					0, 0)) {
		test_err("qgroup counts didn't match expected values");
		return -EINVAL;
	}

	if (btrfs_verify_qgroup_counts(fs_info, BTRFS_FS_TREE_OBJECTID,
					nodesize, nodesize)) {
		test_err("qgroup counts didn't match expected values");
		return -EINVAL;
	}

	return 0;
}

#define TEST_QGROUP(level, id) (((u64)(level) << BTRFS_QGROUP_LEVEL_SHIFT) | (id))

static struct btrfs_qgroup *find_test_qgroup(struct btrfs_fs_info *fs_info,
					     u64 qgroupid)
{
	struct rb_node *node;

	for (node = rb_first(&fs_info->qgroup_tree); node; node = rb_next(node)) {
		struct btrfs_qgroup *qgroup = rb_entry(node, struct btrfs_qgroup, node);

		if (qgroup->qgroupid == qgroupid)
			return qgroup;
	}
	return NULL;
}

static int create_test_qgroup(struct btrfs_trans_handle *trans, u64 qgroupid)
{
	int ret = btrfs_create_qgroup(trans, qgroupid);

	if (ret)
		test_err("couldn't create test qgroup %llu: %d", qgroupid, ret);
	return ret;
}

static int add_test_qgroup_relation(struct btrfs_trans_handle *trans,
				    u64 src, u64 dst)
{
	struct btrfs_qgroup_list *prealloc;

	prealloc = kzalloc_obj(*prealloc, GFP_NOFS);
	if (!prealloc) {
		test_err("failed to allocate test qgroup relation");
		return -ENOMEM;
	}
	return btrfs_add_qgroup_relation(trans, src, dst, prealloc);
}

static int test_qgroup_remove_after_rescan_fallback(struct btrfs_root *root)
{
	struct btrfs_fs_info *fs_info = root->fs_info;
	struct btrfs_trans_handle trans;
	const u64 qgroupid = TEST_QGROUP(1, 10040);
	const u64 parentid = TEST_QGROUP(2, 10040);
	const u64 orphanid = TEST_QGROUP(1, 10041);
	const u64 stock_qgroupid = TEST_QGROUP(1, 10042);
	const u64 stock_parentid = TEST_QGROUP(2, 10042);
	struct btrfs_qgroup *qgroup;
	struct btrfs_qgroup *parent;
	struct btrfs_qgroup *stock_qgroup;
	struct btrfs_qgroup *stock_parent;
	int ret;

	test_msg("running qgroup removal after rescan fallback test");
	if (!fs_info->qgroup_remove_after_rescan_fallback) {
		test_err("qgroup removal fix should be enabled by default");
		return -EINVAL;
	}
	btrfs_init_dummy_trans(&trans, fs_info);
	ret = create_test_qgroup(&trans, qgroupid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, parentid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, qgroupid, parentid);
	if (ret)
		return ret;

	qgroup = find_test_qgroup(fs_info, qgroupid);
	parent = find_test_qgroup(fs_info, parentid);
	if (!qgroup || !parent) {
		test_err("test qgroups disappeared before removal");
		return -ENOENT;
	}

	/* Force relation removal to require a full qgroup rescan. */
	qgroup->rfer = root->fs_info->nodesize;
	ret = btrfs_remove_qgroup(&trans, qgroupid);
	if (ret != 1) {
		test_err("qgroup removal returned %d instead of requesting a rescan", ret);
		return ret < 0 ? ret : -EINVAL;
	}
	if (find_test_qgroup(fs_info, qgroupid) ||
	    !list_empty(&parent->members)) {
		test_err("qgroup or relation remained after successful removal");
		return -EINVAL;
	}

	/* A missing on-disk item is tolerated and must not leak as the result. */
	test_msg("running qgroup removal with a missing info item test");
	ret = create_test_qgroup(&trans, orphanid);
	if (ret)
		return ret;
	ret = btrfs_remove_qgroup(&trans, orphanid);
	if (ret) {
		test_err("qgroup removal returned %d for an absent info item", ret);
		return ret < 0 ? ret : -EINVAL;
	}
	if (find_test_qgroup(fs_info, orphanid)) {
		test_err("qgroup remained after successful removal without an info item");
		return -EINVAL;
	}

	/* Disabling the fix restores stock behavior for this rescan case. */
	test_msg("running stock qgroup removal fallback test");
	ret = create_test_qgroup(&trans, stock_qgroupid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, stock_parentid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, stock_qgroupid, stock_parentid);
	if (ret)
		return ret;
	stock_qgroup = find_test_qgroup(fs_info, stock_qgroupid);
	stock_parent = find_test_qgroup(fs_info, stock_parentid);
	if (!stock_qgroup || !stock_parent) {
		test_err("stock-mode test qgroups disappeared before removal");
		return -ENOENT;
	}
	stock_qgroup->rfer = fs_info->nodesize;
	spin_lock(&fs_info->qgroup_lock);
	fs_info->qgroup_remove_after_rescan_fallback = false;
	spin_unlock(&fs_info->qgroup_lock);
	ret = btrfs_remove_qgroup(&trans, stock_qgroupid);
	if (ret != 1 || find_test_qgroup(fs_info, stock_qgroupid) != stock_qgroup ||
	    !list_empty(&stock_parent->members)) {
		test_err("disabled qgroup removal fix did not retain the stock fallback");
		return ret < 0 ? ret : -EINVAL;
	}
	spin_lock(&fs_info->qgroup_lock);
	fs_info->qgroup_remove_after_rescan_fallback = true;
	spin_unlock(&fs_info->qgroup_lock);
	ret = btrfs_remove_qgroup(&trans, stock_qgroupid);
	if (ret || find_test_qgroup(fs_info, stock_qgroupid)) {
		test_err("qgroup removal fix did not clean up after stock fallback");
		return ret < 0 ? ret : -EINVAL;
	}
	return 0;
}

static int test_qgroup_shared_parent_inherit(struct btrfs_root *root,
					     u32 nodesize)
{
	struct btrfs_fs_info *fs_info = root->fs_info;
	struct btrfs_trans_handle trans;
	const u64 srcid = TEST_QGROUP(0, 10000);
	const u64 parentid = TEST_QGROUP(1, 10000);
	const u64 shared_parentid = TEST_QGROUP(2, 10000);
	struct btrfs_qgroup *src;
	struct btrfs_qgroup *parent;
	struct btrfs_qgroup *shared_parent;
	int ret;

	test_msg("running shared-parent snapshot quick-inherit test");
	btrfs_init_dummy_trans(&trans, fs_info);
	ret = create_test_qgroup(&trans, srcid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, parentid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, shared_parentid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, srcid, shared_parentid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, parentid, shared_parentid);
	if (ret)
		return ret;

	src = find_test_qgroup(fs_info, srcid);
	parent = find_test_qgroup(fs_info, parentid);
	shared_parent = find_test_qgroup(fs_info, shared_parentid);
	if (!src || !parent || !shared_parent) {
		test_err("test qgroups disappeared from the qgroup tree");
		return -ENOENT;
	}

	/*
	 * The common parent's union includes bytes not referenced by the source
	 * alone.  This verifies that the new snapshot parent takes its referenced
	 * count from the common parent rather than from either child.
	 */
	src->rfer = 4 * nodesize;
	src->rfer_cmpr = 2 * nodesize;
	src->excl = 3 * nodesize;
	src->excl_cmpr = nodesize;
	parent->rfer = 2 * nodesize;
	parent->rfer_cmpr = nodesize;
	parent->excl = nodesize;
	parent->excl_cmpr = nodesize / 2;
	shared_parent->rfer = 6 * nodesize;
	shared_parent->rfer_cmpr = 3 * nodesize;
	shared_parent->excl = 3 * nodesize;
	shared_parent->excl_cmpr = nodesize;

	if (!fs_info->qgroup_shared_parent_quick_inherit) {
		test_err("shared-parent quick-inherit should be enabled by default");
		return -EINVAL;
	}
	spin_lock(&fs_info->qgroup_lock);
	fs_info->qgroup_shared_parent_quick_inherit = false;
	spin_unlock(&fs_info->qgroup_lock);
	ret = btrfs_test_qgroup_snapshot_quick_inherit(fs_info, srcid, parentid);
	if (ret != 1 ||
	    btrfs_verify_qgroup_counts(fs_info, srcid, 4 * nodesize,
				       3 * nodesize) ||
	    btrfs_verify_qgroup_counts(fs_info, parentid, 2 * nodesize,
				       nodesize) ||
	    btrfs_verify_qgroup_counts(fs_info, shared_parentid, 6 * nodesize,
				       3 * nodesize) ||
	    src->rfer_cmpr != 2 * nodesize || src->excl_cmpr != nodesize ||
	    parent->rfer_cmpr != nodesize ||
	    parent->excl_cmpr != nodesize / 2 ||
	    shared_parent->rfer_cmpr != 3 * nodesize ||
	    shared_parent->excl_cmpr != nodesize) {
		test_err("disabled shared-parent quick inherit changed counters");
		return -EINVAL;
	}
	spin_lock(&fs_info->qgroup_lock);
	fs_info->qgroup_shared_parent_quick_inherit = true;
	spin_unlock(&fs_info->qgroup_lock);

	ret = btrfs_test_qgroup_snapshot_quick_inherit(fs_info, srcid, parentid);
	if (ret) {
		test_err("shared-parent quick inherit failed: %d", ret);
		return ret < 0 ? ret : -EINVAL;
	}
	if (btrfs_verify_qgroup_counts(fs_info, parentid, 6 * nodesize,
				       2 * nodesize) ||
	    btrfs_verify_qgroup_counts(fs_info, shared_parentid, 7 * nodesize,
				       4 * nodesize) ||
	    parent->rfer_cmpr != 3 * nodesize ||
	    parent->excl_cmpr != nodesize / 2 + nodesize ||
	    shared_parent->rfer_cmpr != 4 * nodesize ||
	    shared_parent->excl_cmpr != 2 * nodesize) {
		test_err("shared-parent quick inherit produced incorrect counters");
		return -EINVAL;
	}
	return 0;
}

static int test_qgroup_inherit_parent_fallbacks(struct btrfs_root *root)
{
	struct btrfs_fs_info *fs_info = root->fs_info;
	struct btrfs_trans_handle trans;
	const u32 nodesize = fs_info->nodesize;
	const u64 srcid = TEST_QGROUP(0, 10010);
	const u64 parentid = TEST_QGROUP(1, 10010);
	const u64 src_parentid = TEST_QGROUP(2, 10011);
	const u64 parent_parentid = TEST_QGROUP(2, 10012);
	const u64 second_src_parentid = TEST_QGROUP(2, 10013);
	const u64 single_srcid = TEST_QGROUP(0, 10020);
	const u64 multi_parentid = TEST_QGROUP(1, 10020);
	const u64 shared_parentid = TEST_QGROUP(2, 10020);
	const u64 other_parentid = TEST_QGROUP(2, 10021);
	const u64 extra_memberid = TEST_QGROUP(0, 10021);
	const u64 overflow_srcid = TEST_QGROUP(0, 10030);
	const u64 overflow_parentid = TEST_QGROUP(1, 10030);
	const u64 overflow_shared_parentid = TEST_QGROUP(2, 10030);
	const u64 overflow_ancestorid = TEST_QGROUP(3, 10030);
	struct btrfs_qgroup *overflow_parent;
	struct btrfs_qgroup *overflow_shared_parent;
	struct btrfs_qgroup *overflow_ancestor;
	u64 *overflow_counters[10];
	u64 *tracked_counters[12];
	u64 counters_before[ARRAY_SIZE(tracked_counters)];
	u64 saved_counter;
	unsigned int i;
	unsigned int j;
	int ret;

	test_msg("running snapshot quick-inherit fallback tests");
	btrfs_init_dummy_trans(&trans, fs_info);
	ret = create_test_qgroup(&trans, srcid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, parentid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, src_parentid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, parent_parentid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, second_src_parentid);
	if (ret)
		return ret;

	/* A different source and snapshot parent must retain the rescan path. */
	ret = add_test_qgroup_relation(&trans, srcid, src_parentid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, parentid, parent_parentid);
	if (ret)
		return ret;
	ret = btrfs_test_qgroup_snapshot_quick_inherit(fs_info, srcid, parentid);
	if (ret != 1) {
		test_err("different-parent topology unexpectedly returned %d", ret);
		return -EINVAL;
	}

	/* A source with multiple parents must also retain the rescan path. */
	ret = add_test_qgroup_relation(&trans, srcid, parent_parentid);
	if (ret)
		return ret;
	ret = btrfs_test_qgroup_snapshot_quick_inherit(fs_info, srcid, parentid);
	if (ret != 1) {
		test_err("multiple-source-parent topology unexpectedly returned %d", ret);
		return -EINVAL;
	}

	ret = add_test_qgroup_relation(&trans, srcid, second_src_parentid);
	if (ret)
		return ret;
	ret = btrfs_test_qgroup_snapshot_quick_inherit(fs_info, srcid, parentid);
	if (ret != 1) {
		test_err("three-source-parent topology unexpectedly returned %d", ret);
		return -EINVAL;
	}

	/* A target with multiple parents is not eligible for the fast path. */
	ret = create_test_qgroup(&trans, single_srcid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, multi_parentid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, shared_parentid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, other_parentid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, extra_memberid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, single_srcid, shared_parentid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, multi_parentid, shared_parentid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, multi_parentid, other_parentid);
	if (ret)
		return ret;
	ret = btrfs_test_qgroup_snapshot_quick_inherit(fs_info, single_srcid,
						       multi_parentid);
	if (ret != 1) {
		test_err("multiple-target-parent topology unexpectedly returned %d", ret);
		return -EINVAL;
	}

	/* A shared parent with any additional child must use the rescan path. */
	ret = add_test_qgroup_relation(&trans, extra_memberid, shared_parentid);
	if (ret)
		return ret;
	ret = btrfs_test_qgroup_snapshot_quick_inherit(fs_info, single_srcid,
						       multi_parentid);
	if (ret != 1) {
		test_err("extra shared-parent member topology unexpectedly returned %d", ret);
		return -EINVAL;
	}

	/* Counter overflow must fall back before changing any counters. */
	test_msg("running snapshot quick-inherit counter overflow tests");
	ret = create_test_qgroup(&trans, overflow_srcid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, overflow_parentid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, overflow_shared_parentid);
	if (ret)
		return ret;
	ret = create_test_qgroup(&trans, overflow_ancestorid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, overflow_srcid,
				       overflow_shared_parentid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, overflow_parentid,
				       overflow_shared_parentid);
	if (ret)
		return ret;
	ret = add_test_qgroup_relation(&trans, overflow_shared_parentid,
				       overflow_ancestorid);
	if (ret)
		return ret;

	overflow_parent = find_test_qgroup(fs_info, overflow_parentid);
	overflow_shared_parent = find_test_qgroup(fs_info,
						  overflow_shared_parentid);
	overflow_ancestor = find_test_qgroup(fs_info, overflow_ancestorid);
	if (!overflow_parent || !overflow_shared_parent || !overflow_ancestor) {
		test_err("overflow test qgroups disappeared from the qgroup tree");
		return -ENOENT;
	}
	overflow_parent->rfer = 3 * root->fs_info->nodesize;
	overflow_parent->rfer_cmpr = 2 * root->fs_info->nodesize;
	overflow_parent->excl = root->fs_info->nodesize;
	overflow_parent->excl_cmpr = root->fs_info->nodesize / 2;
	overflow_shared_parent->rfer = 5 * root->fs_info->nodesize;
	overflow_shared_parent->rfer_cmpr = 3 * root->fs_info->nodesize;
	overflow_shared_parent->excl = 2 * root->fs_info->nodesize;
	overflow_shared_parent->excl_cmpr = root->fs_info->nodesize;
	overflow_ancestor->rfer = 6 * root->fs_info->nodesize;
	overflow_ancestor->rfer_cmpr = 4 * root->fs_info->nodesize;
	overflow_ancestor->excl = 3 * root->fs_info->nodesize;
	overflow_ancestor->excl_cmpr = root->fs_info->nodesize;

	overflow_counters[0] = &overflow_parent->excl;
	overflow_counters[1] = &overflow_parent->excl_cmpr;
	overflow_counters[2] = &overflow_shared_parent->rfer;
	overflow_counters[3] = &overflow_shared_parent->rfer_cmpr;
	overflow_counters[4] = &overflow_shared_parent->excl;
	overflow_counters[5] = &overflow_shared_parent->excl_cmpr;
	overflow_counters[6] = &overflow_ancestor->rfer;
	overflow_counters[7] = &overflow_ancestor->rfer_cmpr;
	overflow_counters[8] = &overflow_ancestor->excl;
	overflow_counters[9] = &overflow_ancestor->excl_cmpr;
	tracked_counters[0] = &overflow_parent->rfer;
	tracked_counters[1] = &overflow_parent->rfer_cmpr;
	tracked_counters[2] = &overflow_parent->excl;
	tracked_counters[3] = &overflow_parent->excl_cmpr;
	tracked_counters[4] = &overflow_shared_parent->rfer;
	tracked_counters[5] = &overflow_shared_parent->rfer_cmpr;
	tracked_counters[6] = &overflow_shared_parent->excl;
	tracked_counters[7] = &overflow_shared_parent->excl_cmpr;
	tracked_counters[8] = &overflow_ancestor->rfer;
	tracked_counters[9] = &overflow_ancestor->rfer_cmpr;
	tracked_counters[10] = &overflow_ancestor->excl;
	tracked_counters[11] = &overflow_ancestor->excl_cmpr;
	for (i = 0; i < ARRAY_SIZE(overflow_counters); i++) {
		saved_counter = *overflow_counters[i];
		*overflow_counters[i] = U64_MAX - nodesize + 1;
		for (j = 0; j < ARRAY_SIZE(tracked_counters); j++)
			counters_before[j] = *tracked_counters[j];

		ret = btrfs_test_qgroup_snapshot_quick_inherit(fs_info,
							       overflow_srcid,
							       overflow_parentid);
		if (ret != 1) {
			test_err("counter overflow unexpectedly returned %d", ret);
			return -EINVAL;
		}
		for (j = 0; j < ARRAY_SIZE(tracked_counters); j++) {
			if (*tracked_counters[j] != counters_before[j]) {
				test_err("counter overflow changed qgroup counters");
				return -EINVAL;
			}
		}
		*overflow_counters[i] = saved_counter;
	}
	return 0;
}

int btrfs_test_qgroups(u32 sectorsize, u32 nodesize)
{
	struct btrfs_fs_info *fs_info = NULL;
	struct btrfs_root *root;
	struct btrfs_root *tmp_root;
	int ret = 0;

	fs_info = btrfs_alloc_dummy_fs_info(nodesize, sectorsize);
	if (!fs_info) {
		test_std_err(TEST_ALLOC_FS_INFO);
		return -ENOMEM;
	}

	root = btrfs_alloc_dummy_root(fs_info);
	if (IS_ERR(root)) {
		test_std_err(TEST_ALLOC_ROOT);
		ret = PTR_ERR(root);
		goto out;
	}

	/* We are using this root as our extent root */
	root->root_key.objectid = BTRFS_EXTENT_TREE_OBJECTID;
	root->root_key.type = BTRFS_ROOT_ITEM_KEY;
	root->root_key.offset = 0;
	btrfs_global_root_insert(root);

	/*
	 * Some of the paths we test assume we have a filled out fs_info, so we
	 * just need to add the root in there so we don't panic.
	 */
	root->fs_info->tree_root = root;
	root->fs_info->quota_root = root;
	set_bit(BTRFS_FS_QUOTA_ENABLED, &fs_info->flags);

	/*
	 * Can't use bytenr 0, some things freak out
	 * *cough*backref walking code*cough*
	 */
	root->node = alloc_test_extent_buffer(root->fs_info, nodesize);
	if (IS_ERR(root->node)) {
		test_err("couldn't allocate dummy buffer");
		ret = PTR_ERR(root->node);
		goto out;
	}
	btrfs_set_header_level(root->node, 0);
	btrfs_set_header_nritems(root->node, 0);
	root->alloc_bytenr += 2 * nodesize;

	tmp_root = btrfs_alloc_dummy_root(fs_info);
	if (IS_ERR(tmp_root)) {
		test_std_err(TEST_ALLOC_ROOT);
		ret = PTR_ERR(tmp_root);
		goto out;
	}

	tmp_root->root_key.objectid = BTRFS_FS_TREE_OBJECTID;
	root->fs_info->fs_root = tmp_root;
	ret = btrfs_insert_fs_root(root->fs_info, tmp_root);
	btrfs_put_root(tmp_root);
	if (ret) {
		test_err("couldn't insert fs root %d", ret);
		goto out;
	}

	tmp_root = btrfs_alloc_dummy_root(fs_info);
	if (IS_ERR(tmp_root)) {
		test_std_err(TEST_ALLOC_ROOT);
		ret = PTR_ERR(tmp_root);
		goto out;
	}

	tmp_root->root_key.objectid = BTRFS_FIRST_FREE_OBJECTID;
	ret = btrfs_insert_fs_root(root->fs_info, tmp_root);
	btrfs_put_root(tmp_root);
	if (ret) {
		test_err("couldn't insert subvolume root %d", ret);
		goto out;
	}

	test_msg("running qgroup tests");
	ret = test_no_shared_qgroup(root, sectorsize, nodesize);
	if (ret)
		goto out;
	ret = test_multiple_refs(root, sectorsize, nodesize);
	if (ret)
		goto out;
	ret = test_qgroup_remove_after_rescan_fallback(root);
	if (ret)
		goto out;
	ret = test_qgroup_shared_parent_inherit(root, nodesize);
	if (ret)
		goto out;
	ret = test_qgroup_inherit_parent_fallbacks(root);
out:
	btrfs_free_dummy_root(root);
	btrfs_free_dummy_fs_info(fs_info);
	return ret;
}
