-- Execute once on a fresh MySQL instance or follow the listed grants for an existing project role.
-- Run against boya_media_center. The role does not grant direct table writes.
CREATE ROLE 'boya_media_center_runtime'@'%';

GRANT SELECT ON boya_media_center.v_current_members TO 'boya_media_center_runtime'@'%';
GRANT SELECT ON boya_media_center.v_member_workload TO 'boya_media_center_runtime'@'%';
GRANT SELECT ON boya_media_center.v_pending_reviews TO 'boya_media_center_runtime'@'%';
GRANT SELECT ON boya_media_center.v_campaign_progress TO 'boya_media_center_runtime'@'%';
GRANT SELECT ON boya_media_center.v_equipment_status TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_create_campaign TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_create_project TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_create_work TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_set_review_route TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_set_campaign_third_review TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_assign_work TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_end_work_assignment TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_log_contribution TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_set_work_status TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_exit_member TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_register_asset TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_submit TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_review_submission TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_forward_rework TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_publish TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_reserve_camera TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_change_camera_usage TO 'boya_media_center_runtime'@'%';
