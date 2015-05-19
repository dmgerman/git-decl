DECL|enumerator|PEEL_BROKEN
DECL|enumerator|PEEL_INVALID
DECL|enumerator|PEEL_IS_SYMREF
DECL|enumerator|PEEL_NON_TAG
DECL|enumerator|PEEL_PEELED
DECL|enumerator|REF_TRANSACTION_CLOSED
DECL|enumerator|REF_TRANSACTION_OPEN
DECL|enum|peel_status
DECL|enum|ref_transaction_state
DECL|function|acquire_packed_ref_cache
DECL|function|add_entry_to_dir
DECL|function|add_packed_ref
DECL|function|add_ref
DECL|function|add_update
DECL|function|check_refname_component
DECL|function|check_refname_format
DECL|function|clear_loose_ref_cache
DECL|function|clear_packed_ref_cache
DECL|function|clear_ref_dir
DECL|function|close_ref
DECL|function|commit_packed_refs
DECL|function|commit_ref
DECL|function|copy_msg
DECL|function|create_dir_entry
DECL|function|create_ref_cache
DECL|function|create_ref_entry
DECL|function|create_symref
DECL|function|delete_ref
DECL|function|delete_ref_loose
DECL|function|delete_reflog
DECL|function|do_for_each_entry
DECL|function|do_for_each_entry_in_dir
DECL|function|do_for_each_entry_in_dirs
DECL|function|do_for_each_ref
DECL|function|do_for_each_reflog
DECL|function|do_head_ref
DECL|function|do_one_ref
DECL|function|dwim_log
DECL|function|dwim_ref
DECL|function|entry_matches
DECL|function|expire_reflog_ent
DECL|function|filter_refs
DECL|function|find_beginning_of_line
DECL|function|find_containing_dir
DECL|function|find_ref
DECL|function|for_each_branch_ref
DECL|function|for_each_branch_ref_submodule
DECL|function|for_each_glob_ref
DECL|function|for_each_glob_ref_in
DECL|function|for_each_namespaced_ref
DECL|function|for_each_rawref
DECL|function|for_each_ref
DECL|function|for_each_ref_in
DECL|function|for_each_ref_in_submodule
DECL|function|for_each_ref_submodule
DECL|function|for_each_reflog
DECL|function|for_each_reflog_ent
DECL|function|for_each_reflog_ent_reverse
DECL|function|for_each_remote_ref
DECL|function|for_each_remote_ref_submodule
DECL|function|for_each_replace_ref
DECL|function|for_each_tag_ref
DECL|function|for_each_tag_ref_submodule
DECL|function|free_ref_entry
DECL|function|get_loose_refs
DECL|function|get_packed_ref
DECL|function|get_packed_ref_cache
DECL|function|get_packed_ref_dir
DECL|function|get_packed_refs
DECL|function|get_ref_cache
DECL|function|get_ref_dir
DECL|function|head_ref
DECL|function|head_ref_namespaced
DECL|function|head_ref_submodule
DECL|function|is_branch
DECL|function|is_dup_ref
DECL|function|is_refname_available
DECL|function|lock_packed_refs
DECL|function|lock_ref_sha1_basic
DECL|function|log_ref_setup
DECL|function|log_ref_write
DECL|function|log_ref_write_1
DECL|function|log_ref_write_fd
DECL|function|nonmatching_ref_fn
DECL|function|pack_if_possible_fn
DECL|function|pack_refs
DECL|function|parse_hide_refs_config
DECL|function|parse_ref_line
DECL|function|peel_entry
DECL|function|peel_object
DECL|function|peel_ref
DECL|function|prettify_refname
DECL|function|prime_ref_dir
DECL|function|prune_ref
DECL|function|prune_refs
DECL|function|read_loose_refs
DECL|function|read_packed_refs
DECL|function|read_ref
DECL|function|read_ref_at
DECL|function|read_ref_at_ent
DECL|function|read_ref_at_ent_oldest
DECL|function|read_ref_full
DECL|function|ref_entry_cmp
DECL|function|ref_entry_cmp_sslice
DECL|function|ref_exists
DECL|function|ref_is_hidden
DECL|function|ref_resolves_to_object
DECL|function|ref_transaction_begin
DECL|function|ref_transaction_commit
DECL|function|ref_transaction_create
DECL|function|ref_transaction_delete
DECL|function|ref_transaction_free
DECL|function|ref_transaction_update
DECL|function|ref_transaction_verify
DECL|function|ref_update_compare
DECL|function|ref_update_reject_duplicates
DECL|function|reflog_exists
DECL|function|reflog_expire
DECL|function|refname_is_safe
DECL|function|refname_match
DECL|function|release_packed_ref_cache
DECL|function|remove_empty_directories
DECL|function|remove_entry
DECL|function|rename_ref
DECL|function|rename_ref_available
DECL|function|rename_tmp_log
DECL|function|repack_without_refs
DECL|function|report_refname_conflict
DECL|function|resolve_gitlink_packed_ref
DECL|function|resolve_gitlink_ref
DECL|function|resolve_gitlink_ref_recursive
DECL|function|resolve_missing_loose_ref
DECL|function|resolve_ref_unsafe
DECL|function|resolve_ref_unsafe_1
DECL|function|resolve_refdup
DECL|function|rollback_packed_refs
DECL|function|search_for_subdir
DECL|function|search_ref_dir
DECL|function|shorten_unambiguous_ref
DECL|function|show_one_reflog_ent
DECL|function|sort_ref_dir
DECL|function|substitute_branch_name
DECL|function|try_remove_empty_parents
DECL|function|unlock_ref
DECL|function|update_ref
DECL|function|verify_lock
DECL|function|warn_dangling_symref
DECL|function|warn_dangling_symrefs
DECL|function|warn_if_dangling_symref
DECL|function|write_packed_entry
DECL|function|write_packed_entry_fn
DECL|function|write_ref_sha1
DECL|macro|DO_FOR_EACH_INCLUDE_BROKEN
DECL|macro|MAXDEPTH
DECL|macro|MAXREFLEN
DECL|macro|PEELED_LINE_LENGTH
DECL|macro|REF_DELETING
DECL|macro|REF_DIR
DECL|macro|REF_HAVE_NEW
DECL|macro|REF_HAVE_OLD
DECL|macro|REF_INCOMPLETE
DECL|macro|REF_ISPRUNING
DECL|macro|REF_KNOWS_PEELED
DECL|macro|TMP_RENAMED_LOG
DECL|member|alloc
DECL|member|alloc
DECL|member|at_time
DECL|member|base
DECL|member|cb_data
DECL|member|cb_data
DECL|member|cnt
DECL|member|cutoff_cnt
DECL|member|cutoff_time
DECL|member|cutoff_tz
DECL|member|date
DECL|member|entries
DECL|member|flag
DECL|member|flags
DECL|member|flags
DECL|member|flags
DECL|member|flags
DECL|member|fn
DECL|member|fn
DECL|member|found
DECL|member|found_it
DECL|member|fp
DECL|member|last_kept_sha1
DECL|member|len
DECL|member|lk
DECL|member|lock
DECL|member|lock
DECL|member|loose
DECL|member|msg
DECL|member|msg
DECL|member|msg_fmt
DECL|member|name
DECL|member|name
DECL|member|name
DECL|member|new_sha1
DECL|member|newlog
DECL|member|next
DECL|member|next
DECL|member|nr
DECL|member|nr
DECL|member|nsha1
DECL|member|old_sha1
DECL|member|old_sha1
DECL|member|orig_ref_name
DECL|member|osha1
DECL|member|packed
DECL|member|packed_refs
DECL|member|pattern
DECL|member|peeled
DECL|member|policy_cb
DECL|member|reccnt
DECL|member|ref_cache
DECL|member|ref_name
DECL|member|ref_to_prune
DECL|member|referrers
DECL|member|refname
DECL|member|refname
DECL|member|refname
DECL|member|refnames
DECL|member|root
DECL|member|sha1
DECL|member|sha1
DECL|member|sha1
DECL|member|should_prune_fn
DECL|member|skip
DECL|member|sorted
DECL|member|state
DECL|member|str
DECL|member|subdir
DECL|member|trim
DECL|member|type
DECL|member|tz
DECL|member|u
DECL|member|updates
DECL|member|validity
DECL|member|value
DECL|struct|expire_reflog_cb
DECL|struct|nonmatching_ref_data
DECL|struct|pack_refs_cb_data
DECL|struct|packed_ref_cache
DECL|struct|read_ref_at_cb
DECL|struct|ref_cache
DECL|struct|ref_dir
DECL|struct|ref_entry
DECL|struct|ref_entry_cb
DECL|struct|ref_filter
DECL|struct|ref_lock
DECL|struct|ref_to_prune
DECL|struct|ref_transaction
DECL|struct|ref_update
DECL|struct|ref_value
DECL|struct|string_slice
DECL|struct|warn_if_dangling_data
DECL|typedef|each_ref_entry_fn
DECL|variable|PACKED_REFS_HEADER
DECL|variable|current_ref
DECL|variable|hide_refs
DECL|variable|packlock
DECL|variable|ref_cache
DECL|variable|ref_rev_parse_rules
DECL|variable|refname_disposition
DECL|variable|submodule_ref_caches
